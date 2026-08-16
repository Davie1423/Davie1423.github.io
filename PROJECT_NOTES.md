# NephroBreath — Project Understanding

## What this is
A webapp + mobile app for **NephroBreath** — a breath-test screening tool
for early chronic kidney disease (CKD), based on an ammonia (NH₃) e-nose
sensor concept ("Smart Electronic Nose for Early CKD Screening"). UI
language is Thai. As of this update, both clients share a real Supabase
backend (Postgres + Auth + Realtime) — see `SETUP.md` for how the sync
works and how to stand up your own project.

## Origin vs. current state
`ReadMe.md` describes 4 planned features for a fuller telehealth product:
1. Patient registration / profile dashboard for clinicians
2. Real-time gas graph via MQTT/HTTP (NH₃ + CO₂) with live AI risk scoring
3. Long-term trend dashboard from historical readings
4. Automated alerts + PDF report export for referral to hospitals

**What's built covers #1 and #3 across two clients**, backed by Supabase
instead of `localStorage`:
- Multi-profile support (add family members, switch between them) — covers
  the "patient registration" idea, but as one symmetric household account
  rather than a clinician/patient role split.
- Home / Reading / Trends / Profile views (webapp: single-page `.view`
  show/hide router; mobile: React Navigation bottom tabs, same 4 screens).
- "ตรวจวัดใหม่" (new reading) flow is a fake 12-second countdown that then
  generates a random NH₃ value drifting off the previous one — there is no
  real device or MQTT/HTTP integration yet. This is the only part still
  simulated client-side; everything else round-trips through Supabase.
- Trends view plots a hand-rolled SVG line chart (webapp: raw `<svg>`
  strings; mobile: `react-native-svg`) with threshold lines at 1.5 and
  3.0 ppm.
- Backup/Restore (JSON) and CSV export exist (webapp only); **PDF export
  and alert/referral automation (item #4) are not implemented.**
- No AI risk model — status (`normal` / `watch` / `elevated`) is a simple
  ppm threshold lookup (`statusFromPpm`), not a learned model.
- No CO₂ reading anywhere, only NH₃.

## File structure
```
index.html            — webapp markup + inline <script>, links Style/style.css
Style/style.css        — webapp styling
supabase-config.js      — webapp's Supabase URL/anon key (fill in per SETUP.md)
supabase/schema.sql     — Postgres schema + RLS policies + realtime setup
mobile/                 — Expo React Native app (same backend as the webapp)
  App.js                  — navigation + auth/data provider wiring
  src/lib/                 — supabase client, config, theme, status/PALETTE (ported from webapp)
  src/context/             — AuthContext (session), DataContext (profiles/readings CRUD + realtime)
  src/screens/             — Login, Home, Reading, Trends, Profile
  src/components/          — Ring, Sparkline, Chart (svg), HistoryItem
SETUP.md                — how to create the Supabase project and run both apps
ReadMe.md               — original Thai concept/spec doc (4 feature ideas)
.qodo/                   — empty Qodo tool scaffolding (agents/, workflows/), no content
```

## Code structure (index.html)
- **State**: global `state` object — `profiles[]`, `readings[]`,
  `activeProfileId`, `range`, `deviceConnected`. Profiles/readings are
  loaded from and written to Supabase (`loadProfiles`/`loadReadings`/
  `loadData`); only `nb_active` (which profile is selected) stays in
  `localStorage`, since it's a per-device UI preference, not shared data.
- **Auth**: `#authScreen` login/signup form, `handleAuthSubmit`, session
  tracked via `sb.auth.onAuthStateChange`; `#appShell` is hidden until a
  session exists.
- **Sync**: `subscribeRealtime()` subscribes to Postgres change events on
  `profiles`/`readings` scoped to the logged-in household and re-renders
  the active view when the *other* client (mobile or another browser tab)
  changes something.
- **Views**: `#view-home`, `#view-reading`, `#view-trends`, `#view-profile`,
  toggled by `goTo(view)`; each has a matching `render*()` function.
- **Reading flow**: idle → countdown (`startReading`) → fake result
  (`finishReading` → `showResult`, now inserting into `readings` via
  Supabase); manual entry modal as an alternative input.
- **Charts**: both the home sparkline and the trends chart are custom SVG
  path builders (no chart library).
- **Data portability**: `exportBackup`/`importBackup` (JSON, now
  round-trips through Supabase inserts), `exportCSV`.

## Mobile app (mobile/)
- Same data model and Supabase project as the webapp — logging in with the
  same account on both shows the same profiles/readings, live.
- `DataContext` mirrors the webapp's state functions (`loadProfiles`,
  `loadReadings`, `addReading`, `addProfile`, `switchProfile`, `clearAll`)
  with a Postgres realtime subscription identical in shape to the
  webapp's `subscribeRealtime`.
- `nb_active` (selected profile) persisted via `AsyncStorage` instead of
  `localStorage` — same per-device-only semantics as the webapp.

## Notable gaps if this is meant to become the real product
- No real sensor/device integration (Bluetooth/MQTT/HTTP) — readings are
  still `Math.random()`-generated, same as before; `toggleDeviceStatus` in
  the webapp still just flips a boolean.
- No clinician role — every account is a symmetric "household," not the
  clinician-vs-patient split described in ReadMe.md's original concept.
- No PDF report generation or alert/referral system (ReadMe item #4).
- No CO₂ channel, no AI-based risk classification.
- Mobile app has no native build/store submission set up yet — it currently
  only runs via Expo Go / dev client (`npx expo start`).