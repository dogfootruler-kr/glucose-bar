# GlucoseBar

FreeStyle Libre glucose in the macOS menu bar, without Android/ADB.

Phone (Libre app) → LibreView cloud → LibreLinkUp API → `server/libre_server.py` (localhost:8765, SQLite history) → `GlucoseBar.app`

## Features
- Menu bar: value, trend arrow, change over 5 min, 1–3h trend line, colour by target range; optional dot-only when in range
- Dropdown: 3/6/12/24h chart, time in range / average / A1c estimate (today and 7 days), sensor expiry countdown
- Alerts: low, high, fast drop below 100 mg/dL, no data for N minutes; snooze 30 min from the notification or the menu
- Server: keeps every reading in `~/Library/Application Support/freestyle-bar/glucose.db`, CSV export, web page at `http://localhost:8765` (optionally shared on the local network)
- Settings window: units, target range, alert thresholds, menu bar display, open at login

## Setup
1. Install **LibreLinkUp** on your phone and create a *separate* account (a follower account).
2. In the FreeStyle Libre app: Menu → Share / Connected Apps → LibreLinkUp → add that email. Accept the invite in LibreLinkUp, and accept any terms there.
3. `./install.sh`, then enter the follower account's email and password. The password is stored in the Keychain.

Logs: `~/Library/Logs/freestyle-bar.log`

## Server API
| Path | |
|---|---|
| `/` | web page |
| `/glucose?hours=12` | latest reading, delta, sensor, history |
| `/stats?low=70&high=180` | today / 7-day stats |
| `/export.csv` | all stored readings |
