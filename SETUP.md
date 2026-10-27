# NephroBreath — Backend & Sync Setup

Three clients share one Supabase backend: the ESP32 device, the Flutter
mobile app (`mobile/`), and the web dashboard (`index.html`). A test session
uploaded by the device shows up on both apps in real time; a manual entry
made in either app shows up everywhere else the same way.

## 1. Create a Supabase project

1. Go to https://supabase.com, sign in, and create a new project (free tier
   is enough).
2. Wait for it to finish provisioning, then open **SQL Editor** in the
   left sidebar.
3. Paste in the contents of `supabase/schema.sql` from this repo and run
   it. This creates the `devices`, `patients`, and `test_sessions` tables,
   the processing-pipeline trigger, row-level security policies, and
   enables realtime on `patients`/`test_sessions`.
4. Go to **Project Settings → API**. You'll need two values from here:
   - **Project URL** (e.g. `https://abcxyz.supabase.co`)
   - **anon public** key (a long JWT-looking string, or the newer
     `sb_publishable_...` key)

### Optional: skip email confirmation for local testing

By default Supabase requires confirming a signup email before login works.
For local testing that's extra friction — go to **Authentication →
Providers → Email** and turn off "Confirm email" if you want signups to
work immediately. Turn it back on before shipping to real users.

## 2. Create a staff account

Staff (clinicians/operators) sign up directly from the web dashboard or the
mobile app's login screen with an email + password. Any account that is
**not** listed in the `devices` table is treated as staff and can create
patients, enter manual readings, and see every patient's history (see
`is_staff()` / `is_device()` in `supabase/schema.sql`).

## 3. Register a device (optional, only needed for real hardware)

Each ESP32 unit authenticates as its own Supabase Auth user so it can
insert/update `test_sessions` without having staff-level access to the
`patients` table. To provision one:

1. In the Supabase dashboard, go to **Authentication → Users → Add user**
   and create an account for the device (e.g.
   `device-nb-001@nephrobreath.local` with a long random password). Copy
   its user UUID.
2. In **SQL Editor**, link it to a human-readable code:
   ```sql
   insert into public.devices (auth_user_id, device_code, label)
   values ('<the device user uuid>', 'NB-001', 'Clinic front desk unit');
   ```
3. On the ESP32, sign in with that email/password via the Supabase REST
   auth endpoint (`POST /auth/v1/token?grant_type=password`) to get an
   access token, then use that token as the `Authorization: Bearer`
   header on `test_sessions` inserts/updates to the REST API
   (`/rest/v1/test_sessions`).

You don't need a device registered to use either app — the "บันทึกผลด้วย
ตนเอง" (manual entry) flow in both clients exercises the exact same
`test_sessions` table and processing-pipeline trigger without any hardware.

## 4. Point the web dashboard at it

Edit `supabase-config.js` at the repo root:

```js
window.SUPABASE_URL = 'https://abcxyz.supabase.co';
window.SUPABASE_ANON_KEY = 'ey... or sb_publishable_...';
```

Then just open `index.html` in a browser (or serve the folder with any
static file server). You'll land on a staff login/signup screen.

## 5. Point the mobile app at it

Edit `mobile/lib/config.dart` with the **same** URL and anon key:

```dart
const supabaseUrl = 'https://abcxyz.supabase.co';
const supabaseAnonKey = 'ey... or sb_publishable_...';
```

Then run it:

```bash
cd mobile
flutter pub get
flutter run
```

Sign in with the same staff account you created in step 2 — you'll see the
same patients and sessions, live.

## How the sync works

- All three clients talk directly to the same Supabase Postgres database;
  there's no separate custom backend server to run.
- **Auth**: staff accounts are full read/write on `patients` and
  `test_sessions`; device accounts can only create/update `test_sessions`
  (see the RLS policies in `supabase/schema.sql`).
- **Processing pipeline**: a `before insert or update` trigger on
  `test_sessions` (`compute_session_pipeline()`) does baseline drift
  correction, temperature/humidity compensation, noise filtering, feature
  extraction (peak ΔR/R0, slope, AUC), and risk classification server-side
  — so the device only needs to upload raw readings/curves, not do the math
  itself.
- **Risk classification**: currently a rule-based threshold on
  `corrected_nh3` (`risk_model = 'rule-based-v1'`), not a trained ML model.
  `peak_response`/`absorption_slope`/`auc` are stored on every session so a
  real classifier can be swapped in later without a schema change. See
  `PROJECT_NOTES.md`.
- **Realtime**: both apps subscribe to Postgres change events on
  `patients`/`test_sessions` and reload + re-render automatically when a
  change comes in from another client. This is what powers the "live test
  in progress" view.

## Simulating a device session without hardware

With a staff session's access token, you can insert a session via the REST
API to test the live view / pipeline end-to-end:

```bash
curl -X POST 'https://abcxyz.supabase.co/rest/v1/test_sessions' \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $STAFF_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "patient_id": "<existing patient uuid>",
    "status": "in_progress"
  }'
```

Then `PATCH` the same row (by `id`) as the "device" would, adding
`co2_curve`, `gating_t`, `tube_nh3`, `ambient_nh3`, `nh3_curve`,
`temperature`, `humidity`, and finally `"status": "completed"` — the
trigger recomputes `corrected_nh3`, the extracted features, and
`risk_level` on every update.

## What's still simulated / not built

- No real ESP32 firmware in this repo — the device-side behavior described
  above (alveolar gating, dual NH₃ sensors, CO₂/temp/humidity sampling) is
  the target the schema and apps are built against, not code that runs on
  real hardware.
- No trained ML model — see "Risk classification" above.
- No PDF report export / automated referral alerts.
