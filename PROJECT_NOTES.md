# NephroBreath — Project Understanding

## What this is
A companion app system for **NephroBreath** — a portable, non-invasive
breath-ammonia (NH₃) screening device for early-stage chronic kidney
disease (CKD). Hardware target: ESP32-WROOM, 2× MiCS-6814 gas sensors (one
breath-facing "tube" sensor, one outward-facing "ambient" sensor), 1×
SCD40 (CO₂/temp/humidity), LCD touchscreen, and a servo/solenoid valve that
implements "alveolar air gating" — it only opens to sample air once
exhaled CO₂ plateaus at the alveolar threshold (~4–5%), so the sensors see
deep-lung air, not mouth/dead-space air. UI language is Thai.

This is a screening/risk-assessment tool, not a diagnostic device — every
result screen says so explicitly.

## System architecture
Three clients, one Supabase backend (Postgres + Auth + Realtime):
- **Device** (ESP32 touchscreen) — uploads each test session's raw
  readings/curves to Supabase. No real firmware lives in this repo; the
  schema and apps are built against this target so a real device can be
  dropped in later (see `SETUP.md` for how it would authenticate and what
  it needs to upload).
- **Mobile app** (`mobile/`, Flutter + `supabase_flutter`) — same views as
  the web dashboard.
- **Web dashboard** (`index.html`) — clinician/operator-facing.

All three read/write the same `patients` / `test_sessions` tables and
subscribe to the same realtime channels, so a session started on the
device (or entered manually in either app) appears live everywhere else.

## Data model (`supabase/schema.sql`)
- **`patients`** — looked up/created by `patient_code` (clinic-assigned
  ID), not scoped to a single login. Any staff account can see any
  patient's full history across visits — this is a clinic tool, not a
  per-household app like the project's earlier iteration was.
  `patient_auth_user_id` optionally links a patient's own login (see
  "Account roles" below); null until they self-link.
- **Account roles** — three kinds of signed-in principal, distinguished by
  `is_device()` / `is_patient()` / `is_staff()` in `schema.sql`:
  - **staff** (default) — full read/write on `patients`; staff-or-device
    read/write on `test_sessions`.
  - **device** — one per ESP32 unit (`devices` table), can create/update
    `test_sessions` only.
  - **patient** — self-signup in the web dashboard, role stored in Supabase
    Auth `user_metadata.role`. Links to their own `patients` row by
    entering their `patient_code` once (RLS policy "patients: patient
    self-link"); after that, read-only access to their own patient record
    and their own `test_sessions` rows. Cannot insert/update/delete
    anything. The web dashboard (`index.html`) shows a trimmed read-only
    portal for this role (`body.patient-mode`) instead of the full staff
    shell.
- **`test_sessions`** — one row per breath test:
  - `tube_nh3` / `ambient_nh3` → `corrected_nh3` (generated column:
    tube − ambient)
  - `co2_curve` (jsonb array of `{t, co2}` samples) + `gating_t`/
    `gating_co2` (when the alveolar valve opened)
  - `nh3_curve` (jsonb array of `{t, r}` raw sensor response during the
    gated sampling window) → feeds feature extraction
  - `temperature`, `humidity`
  - extracted features: `peak_response` (peak ΔR/R0), `absorption_slope`,
    `auc`
  - `risk_level` (`normal` | `elevated`), `risk_score`, `risk_model`
  - `status` (`in_progress` → `gating` → `completed`, or `error`) — this is
    what powers the live-test view
- **`devices`** — links a device's own Supabase Auth login to a
  human-readable `device_code`, so RLS can tell device logins apart from
  staff logins (`is_device()` / `is_staff()`).

### Processing pipeline
A `before insert or update` trigger on `test_sessions`
(`compute_session_pipeline()`) does all five pipeline steps server-side,
so the device only has to upload raw data:
1. Baseline drift correction (first `nh3_curve` sample as reference)
2. Temperature/humidity compensation (linear, placeholder coefficients)
3. Noise filtering (two-point moving average)
4. Feature extraction (peak ΔR/R0, slope, AUC via trapezoidal integration)
5. Risk classification

**Step 5 is a rule-based threshold on `corrected_nh3`
(`risk_model = 'rule-based-v1'`), not a trained ML model.** This mirrors
this project's existing honest-scoping pattern (the original ppm-threshold
`statusFromPpm` logic from the household-tracking version). The extracted
features are stored on every session specifically so a trained classifier
can be swapped in later without touching the schema.

## Web dashboard (`index.html`)
Rebuilt from the ground up around the new data model (the previous version
was a household self-tracking app; see "Origin vs. current state" below).
Views: Home (stats + recent sessions + live-test banner), Patients
(search/create by `patient_code`), Patient Detail (trend chart across that
patient's `corrected_nh3` over time + session history), Session Result
(risk banner, CO₂ curve with the gating point marked, extracted features),
Live Test (realtime view of an in-progress session, auto-navigates to the
result once `status` flips to `completed`), Account (sign out, CSV
export). No build step — vanilla JS/HTML/CSS/SVG, same as before, styled
with the existing forest/sage/clay design system in `Style/style.css`.

Manual session entry (tube/ambient NH₃ + temp/humidity, no device
required) exercises the exact same insert path and trigger a real device
would use — this is how the whole pipeline can be tested without hardware.

## Mobile app (`mobile/`)
**Not yet built in this checkout.** Earlier project notes described a
React Native app under `mobile/`, but that directory does not exist in
this repo as of this update. The plan is a Flutter app
(`supabase_flutter` + `fl_chart`) mirroring the web dashboard's views
against the same schema — see the Flutter-specific task/handoff notes if
a build is in progress, or `SETUP.md` once it exists.

## Origin vs. earlier iteration
This project previously had a different shape: a household
self-tracking app (`profiles`/`readings` tables, one Supabase Auth account
per family, a simulated 12-second "ตรวจวัดใหม่" countdown generating a
random NH₃ value). That data model, UI, and the old `mobile/` React Native
app have all been replaced by the clinic/device-oriented system described
above, built against the hardware spec (dual NH₃ sensors, CO₂-gated
sampling, ESP32/Flutter/web). The oldest layer — `ReadMe.md` — is the
original 4-feature Thai concept doc predating either iteration; of its
4 items, this version covers #1 (patient lookup/registration, now as a
clinic tool) and #3 (trend dashboard), but still has no PDF export /
automated referral (item #4) and no CO₂-based AI model beyond the
rule-based classifier described above.

## Notable gaps if this is meant to become the real product
- No real ESP32 firmware — the schema/apps are built against the hardware
  spec but nothing in this repo runs on actual hardware yet.
- No trained ML model for risk classification (see pipeline step 5 above).
- No PDF report generation or alert/referral system.
- No device-provisioning UI in either app — registering a device
  (`devices` table) is a manual SQL step for now (see `SETUP.md`); this
  was left out deliberately since no "core app feature" in the spec asked
  for device management UI, only patient-facing flows.
