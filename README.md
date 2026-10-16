# GlucoseBar

FreeStyle Libre glucose in the macOS menu bar, without Android/ADB.

Phone (Libre app) → LibreView cloud → LibreLinkUp API → `server/libre_server.py` (localhost:8765, SQLite history) → `GlucoseBar.app`

## Features
- Menu bar: value, trend arrow, change over 5 min, 1–3h trend line, colour by target range; optional dot-only when in range
- Dropdown: 3/6/12/24h chart, time in range / average / A1c estimate (today and 7 days), sensor expiry countdown
- Alerts: low, high, fast drop below 100 mg/dL, no data for N minutes; snooze 30 min from the notification or the menu
- Server: keeps every reading in `~/Library/Application Support/freestyle-bar/glucose.db`, CSV export, web page at `http://localhost:8765` (optionally shared on the local network)
- Settings window: units, target range, alert thresholds, menu bar display, open at login
- Forecast: 30-minute projection from the last 20 minutes (dotted line), with a "heading low" alert up to 20 minutes ahead
- Meal and insulin log (popup `+` button or the web page, including from a phone camera); Claude estimates carbs from a photo
- Meal impact: rise, time to peak, time above range and a 0-100 score per meal; ranking in Meals
- Weekly summary written by Claude every Sunday from 19:00, or on demand

Meal estimates and weekly summaries use the Claude Agent SDK, which runs on the Claude subscription you're logged into with `claude` (no API key).

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
| `/events` | GET / POST meals and insulin; `DELETE /events/<id>` |
| `/meals?days=30` | meals with glucose impact |
| `/meals/estimate` | POST photo/text, returns a carb estimate |
| `/summary`, `/summary/generate` | weekly summary |
