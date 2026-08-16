# NephroBreath — Backend & Sync Setup

The webapp (`index.html`) and the mobile app (`mobile/`) now share one
Supabase backend, so a reading logged on either one shows up on the other
in real time. This doc covers getting that backend running and pointing
both apps at it.

## 1. Create a Supabase project

1. Go to https://supabase.com, sign in, and create a new project (free tier
   is enough).
2. Wait for it to finish provisioning, then open **SQL Editor** in the
   left sidebar.
3. Paste in the contents of `supabase/schema.sql` from this repo and run
   it. This creates the `profiles` and `readings` tables, row-level
   security policies (so each account only ever sees its own data), and
   enables realtime on both tables.
4. Go to **Project Settings → API**. You'll need two values from here:
   - **Project URL** (e.g. `https://abcxyz.supabase.co`)
   - **anon public** key (a long JWT-looking string)

### Optional: skip email confirmation for local testing

By default Supabase requires confirming a signup email before login works.
For local testing that's extra friction — go to **Authentication →
Providers → Email** and turn off "Confirm email" if you want signups to
work immediately. Turn it back on before shipping to real users.

## 2. Point the webapp at it

Edit `supabase-config.js` at the repo root:

```js
window.SUPABASE_URL = 'https://abcxyz.supabase.co';
window.SUPABASE_ANON_KEY = 'ey...';
```

Then just open `index.html` in a browser (or serve the folder with any
static file server). You'll land on a login/signup screen — sign up once,
and the app auto-creates a default "คุณเอง" profile for that account.

## 3. Point the mobile app at it

Edit `mobile/src/lib/config.js` with the **same** URL and anon key:

```js
export const SUPABASE_URL = 'https://abcxyz.supabase.co';
export const SUPABASE_ANON_KEY = 'ey...';
```

Then run it:

```bash
cd mobile
npm install   # first time only
npx expo start
```

Scan the QR code with Expo Go (iOS/Android) or press `i` / `a` to open an
iOS Simulator / Android Emulator. Sign in with the **same account** you
created in the webapp — you'll see the same profiles and readings.

## How the sync works

- Both apps talk directly to the same Supabase Postgres database via the
  `@supabase/supabase-js` client — there's no separate custom backend
  server to run.
- **Auth** = one Supabase account per household (email/password). Every
  `profiles` row is scoped to `household_id = auth.uid()`, so multiple
  family members can live under one login, matching the existing
  profile-switcher UI.
- **Row-level security** (in `supabase/schema.sql`) enforces that an
  account can only read/write its own rows — this is the actual security
  boundary, not something either client enforces.
- **Realtime**: both apps subscribe to Postgres change events on
  `profiles`/`readings` filtered to the logged-in household, and reload
  + re-render automatically when a change comes in from the *other* app.
  Log a reading on your phone, and it appears on the webapp within a
  second or two without a manual refresh.

## What's still simulated

Per the current scope, this covers accounts + data sync between the two
clients. It does **not** yet include:
- Real sensor/device integration (Bluetooth/MQTT/HTTP) — readings from
  the "ตรวจวัดใหม่" flow are still randomly generated, same as before.
- PDF report export / automated referral alerts (ReadMe.md item #4).
- A separate clinician role — every login is a symmetric "household"
  account, not the clinician-vs-patient split described in ReadMe.md's
  original telehealth-dashboard concept.
