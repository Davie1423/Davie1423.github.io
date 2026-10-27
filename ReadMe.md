Build the companion app system for NephroBreath — a portable, non-invasive breath
screening device for early-stage chronic kidney disease (CKD).

## Context
The device measures breath ammonia (NH3), which correlates with blood urea nitrogen.
Hardware: ESP32-WROOM, 2× MiCS-6814 gas sensors, 1× SCD40 (CO2/temp/humidity),
LCD touchscreen. It uses "alveolar air gating": a servo/solenoid valve opens only
when exhaled CO2 plateaus at the alveolar threshold (~4–5% / ~40 mmHg), so only
deep-lung air is sampled, not mouth/dead-space air.

## System architecture
- Three clients: device touchscreen (ESP32), mobile app, web app
- All sync through a Supabase backend (auth, Postgres DB, realtime)
- ESP32 uploads each test session to Supabase; apps read and display it

## Data per test session
- Patient ID, timestamp
- Tube NH3 reading (breath sensor)
- Ambient NH3 reading (outward-facing sensor)
- Corrected NH3 = tube − ambient
- CO2 curve during exhalation + the point where alveolar gating triggered
- Temperature, humidity
- Extracted features: peak response (ΔR/R0), absorption slope, area under curve
- Risk classification: Normal vs. Elevated risk of renal impairment

## Processing pipeline (device or backend)
1. Baseline drift correction
2. Temperature/humidity compensation
3. Noise filtering of raw gas resistance
4. Feature extraction (peak ΔR/R0, slope, AUC)
5. ML classification → risk level

## Core app features
- Patient ID lookup / create
- Single test works on its own (no repeat test required)
- If the same patient ID is used across visits, accumulate all results and show a
  trend graph of whether values are improving or worsening over time
- Result screen: corrected NH3, risk level, CO2 curve with gating point marked
- Session history list per patient
- Live view of a test in progress (realtime from Supabase)

## Platforms
- Mobile app: Flutter
- Web app: dashboard for viewing patients, trends, and session detail
- Shared Supabase schema across both

## Note
This is a screening/risk-assessment tool, not a diagnosis — results UI should say so.