-- NephroBreath — Supabase schema (device + clinician/mobile/web system)
-- Run this once in the Supabase SQL editor (or via `supabase db push`).
--
-- Model: clinic-wide shared visibility. Every signed-in principal is either
-- a staff account (clinician/operator, full read/write on patients) or a
-- device account (one per ESP32 unit, can only create/update test_sessions).
-- Patient lookup is by `patient_code` (e.g. hospital MRN or a printed card
-- code), not scoped per-login, since any staff member or the device itself
-- may pull up any patient's history across visits.

create extension if not exists "pgcrypto";

-- ============================================================
-- devices — one row per physical ESP32 unit
-- ============================================================
-- Each device authenticates as its own Supabase Auth user (created once via
-- the dashboard or admin API with a long random password / service-issued
-- token), then this table links that auth user to a human-readable code so
-- RLS can tell "this login is a device, not a clinician" (see is_device()).
create table if not exists public.devices (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid unique references auth.users(id) on delete cascade,
  device_code   text unique not null,
  label         text,
  created_at    timestamptz not null default now()
);

-- ============================================================
-- patients
-- ============================================================
create table if not exists public.patients (
  id            uuid primary key default gen_random_uuid(),
  patient_code  text unique not null,
  name          text,
  sex           text check (sex in ('male', 'female', 'other')),
  birth_year    int,
  created_by    uuid references auth.users(id),
  -- set once a patient signs up and links their own account via patient_code
  -- (see "patients: patient self-link" policy below).
  patient_auth_user_id uuid unique references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);

create index if not exists patients_patient_code_idx on public.patients (patient_code);

create or replace function public.normalize_patient_code()
returns trigger
language plpgsql
as $$
begin
  new.patient_code := upper(trim(new.patient_code));
  return new;
end;
$$;

drop trigger if exists trg_patients_normalize_code on public.patients;
create trigger trg_patients_normalize_code
  before insert or update on public.patients
  for each row execute function public.normalize_patient_code();

-- ============================================================
-- test_sessions — one row per breath test (device-uploaded or manual entry)
-- ============================================================
create table if not exists public.test_sessions (
  id                 uuid primary key default gen_random_uuid(),
  patient_id         uuid not null references public.patients(id) on delete cascade,
  device_id          uuid references public.devices(id),

  status             text not null default 'in_progress'
                       check (status in ('in_progress', 'gating', 'completed', 'error')),
  started_at         timestamptz not null default now(),
  completed_at       timestamptz,

  -- raw sensor readings
  tube_nh3           numeric(8,3),   -- breath (tube-facing) sensor, ppm-equivalent
  ambient_nh3        numeric(8,3),   -- outward-facing sensor, ppm-equivalent
  corrected_nh3      numeric(8,3) generated always as (tube_nh3 - ambient_nh3) stored,

  co2_curve          jsonb,          -- [{ "t": seconds, "co2": pct }, ...] exhalation curve
  nh3_curve          jsonb,          -- [{ "t": seconds, "r": raw_response }, ...] gated sampling window
  gating_t           numeric(6,2),   -- time (s) alveolar gating valve opened
  gating_co2         numeric(5,2),   -- CO2 % at the gating point

  temperature        numeric(5,2),
  humidity            numeric(5,2),

  -- extracted features (pipeline step 4)
  peak_response       numeric(8,4),  -- peak delta-R/R0
  absorption_slope     numeric(10,6),
  auc                  numeric(10,4),

  -- classification (pipeline step 5)
  risk_level           text check (risk_level in ('normal', 'elevated')),
  risk_score           numeric(5,2),
  risk_model            text default 'rule-based-v1',

  notes                 text default '',
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create index if not exists test_sessions_patient_id_started_at_idx
  on public.test_sessions (patient_id, started_at);
create index if not exists test_sessions_status_idx
  on public.test_sessions (status) where status in ('in_progress', 'gating');

alter table public.test_sessions replica identity full;

-- ------------------------------------------------------------
-- processing pipeline: baseline correction, temp/humidity
-- compensation, noise filtering, feature extraction, and a
-- rule-based risk classifier (pipeline steps 1-5).
--
-- NOTE on step 5: there is no trained ML model yet. This mirrors the
-- project's existing honest scoping (see PROJECT_NOTES.md) — it's a
-- threshold rule on corrected_nh3 using the same 1.5/3.0 ppm cutoffs used
-- elsewhere in the app. peak_response / absorption_slope / auc are computed
-- and stored on every session specifically so a trained classifier can be
-- swapped in later (bump risk_model) without any schema change.
-- ------------------------------------------------------------
create or replace function public.compute_session_pipeline()
returns trigger
language plpgsql
as $$
declare
  v_elem      jsonb;
  v_t         numeric;
  v_r         numeric;
  v_comp      numeric;
  v_baseline  numeric;
  v_rel       numeric;
  v_peak      numeric;
  v_peak_t    numeric;
  v_auc       numeric := 0;
  v_prev_t    numeric;
  v_prev_rel  numeric;
  v_is_first  boolean := true;
  v_temp_k    numeric := 0.02;  -- placeholder temp-compensation coeff, per deg C from 25C ref
  v_hum_k     numeric := 0.01;  -- placeholder humidity-compensation coeff, per %RH from 50% ref
  v_gate_elem jsonb;
  v_corrected numeric;
begin
  new.updated_at := now();
  if new.status = 'completed' and new.completed_at is null then
    new.completed_at := now();
  end if;

  -- feature extraction from the raw NH3 response curve (steps 1-4)
  if new.nh3_curve is not null
     and jsonb_typeof(new.nh3_curve) = 'array'
     and jsonb_array_length(new.nh3_curve) >= 2 then
    for v_elem in select * from jsonb_array_elements(new.nh3_curve) loop
      v_t := (v_elem->>'t')::numeric;
      v_r := (v_elem->>'r')::numeric;

      -- step 2: temperature / humidity compensation
      v_comp := v_r
        - v_temp_k * (coalesce(new.temperature, 25) - 25)
        - v_hum_k  * (coalesce(new.humidity, 50) - 50);

      if v_is_first then
        v_baseline := v_comp;  -- step 1: baseline drift correction reference
        v_is_first := false;
        v_peak := 0;
        v_peak_t := v_t;
        v_prev_t := v_t;
        v_prev_rel := 0;
        continue;
      end if;

      -- step 3: noise filtering — simple two-point moving average
      v_rel := (v_comp - v_baseline + v_prev_rel) / 2;

      if v_rel > v_peak then
        v_peak := v_rel;
        v_peak_t := v_t;
      end if;

      v_auc := v_auc + (v_rel + v_prev_rel) / 2 * (v_t - v_prev_t);

      v_prev_t := v_t;
      v_prev_rel := v_rel;
    end loop;

    new.peak_response := round(v_peak, 4);
    new.absorption_slope := case when v_peak_t > 0 then round(v_peak / v_peak_t, 6) else null end;
    new.auc := round(v_auc, 4);
  end if;

  -- derive the gating point from the CO2 curve if the device didn't report one directly
  if new.gating_t is null
     and new.co2_curve is not null
     and jsonb_typeof(new.co2_curve) = 'array' then
    for v_gate_elem in select * from jsonb_array_elements(new.co2_curve) loop
      if (v_gate_elem->>'co2')::numeric >= 4.0 then
        new.gating_t := (v_gate_elem->>'t')::numeric;
        new.gating_co2 := (v_gate_elem->>'co2')::numeric;
        exit;
      end if;
    end loop;
  end if;

  -- step 5: rule-based risk classification (see note above)
  if new.tube_nh3 is not null and new.ambient_nh3 is not null then
    v_corrected := new.tube_nh3 - new.ambient_nh3;
    new.risk_level := case when v_corrected >= 3.0 then 'elevated' else 'normal' end;
    new.risk_score := round(least(100, greatest(0, v_corrected / 4.0 * 100)), 1);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_test_sessions_pipeline on public.test_sessions;
create trigger trg_test_sessions_pipeline
  before insert or update on public.test_sessions
  for each row execute function public.compute_session_pipeline();

-- ============================================================
-- auth helpers
-- ============================================================
create or replace function public.is_device()
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.devices d where d.auth_user_id = auth.uid()
  );
$$;

-- a patient's own login (see patients.patient_auth_user_id); role is carried
-- in auth user_metadata, set at signup time by the web app.
create or replace function public.is_patient()
returns boolean
language sql
stable
as $$
  select coalesce((auth.jwt() -> 'user_metadata' ->> 'role') = 'patient', false);
$$;

create or replace function public.is_staff()
returns boolean
language sql
stable
as $$
  select auth.uid() is not null and not public.is_device() and not public.is_patient();
$$;

-- ============================================================
-- row level security
-- ============================================================
alter table public.devices enable row level security;
alter table public.patients enable row level security;
alter table public.test_sessions enable row level security;

create policy "devices: staff manage" on public.devices
  for all using (public.is_staff()) with check (public.is_staff());

create policy "patients: staff manage" on public.patients
  for all using (public.is_staff()) with check (public.is_staff());

-- a patient can see their own linked record...
create policy "patients: own record select" on public.patients
  for select using (patient_auth_user_id = auth.uid());

-- ...and can claim an unlinked record once, by patient_code, at signup.
create policy "patients: patient self-link" on public.patients
  for update
  using (public.is_patient() and patient_auth_user_id is null)
  with check (patient_auth_user_id = auth.uid());

-- staff/device have full read/write; a patient can only read their own
-- sessions (via the patients link above) and can never insert/update/delete.
create policy "test_sessions: read access" on public.test_sessions
  for select using (
    public.is_staff()
    or public.is_device()
    or exists (
      select 1 from public.patients p
      where p.id = test_sessions.patient_id
        and p.patient_auth_user_id = auth.uid()
    )
  );
create policy "test_sessions: staff or device can insert" on public.test_sessions
  for insert with check (public.is_staff() or public.is_device());
create policy "test_sessions: staff or device can update" on public.test_sessions
  for update using (public.is_staff() or public.is_device())
  with check (public.is_staff() or public.is_device());
create policy "test_sessions: staff can delete" on public.test_sessions
  for delete using (public.is_staff());

-- ============================================================
-- realtime (web dashboard + mobile app + live-test view)
-- ============================================================
alter publication supabase_realtime add table public.patients;
alter publication supabase_realtime add table public.test_sessions;
