-- NephroBreath — Supabase schema
-- Run this once in the Supabase SQL editor (or via `supabase db push`).
-- Model: one auth.users row = one "household" account (matches the
-- webapp's existing multi-profile-per-account UI). Each profile belongs
-- to exactly one household; each reading belongs to exactly one profile.

create extension if not exists "pgcrypto";

-- ---------- profiles ----------
create table if not exists public.profiles (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references auth.users(id) on delete cascade,
  name          text not null,
  age           text,
  color         text not null default '#1F4B3C',
  created_at    timestamptz not null default now()
);

-- ---------- readings ----------
create table if not exists public.readings (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null references public.profiles(id) on delete cascade,
  household_id  uuid not null references auth.users(id) on delete cascade,
  nh3           numeric(6,2) not null,
  note          text default '',
  ts            timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

create index if not exists readings_profile_id_ts_idx on public.readings (profile_id, ts);
create index if not exists profiles_household_id_idx on public.profiles (household_id);

-- ---------- row level security ----------
alter table public.profiles enable row level security;
alter table public.readings enable row level security;

create policy "profiles: household can read own" on public.profiles
  for select using (household_id = auth.uid());
create policy "profiles: household can insert own" on public.profiles
  for insert with check (household_id = auth.uid());
create policy "profiles: household can update own" on public.profiles
  for update using (household_id = auth.uid());
create policy "profiles: household can delete own" on public.profiles
  for delete using (household_id = auth.uid());

create policy "readings: household can read own" on public.readings
  for select using (household_id = auth.uid());
create policy "readings: household can insert own" on public.readings
  for insert with check (household_id = auth.uid());
create policy "readings: household can update own" on public.readings
  for update using (household_id = auth.uid());
create policy "readings: household can delete own" on public.readings
  for delete using (household_id = auth.uid());

-- ---------- realtime (so webapp + mobile app see live updates) ----------
alter publication supabase_realtime add table public.profiles;
alter publication supabase_realtime add table public.readings;
