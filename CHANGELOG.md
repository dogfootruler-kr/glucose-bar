# Changelog

Each release needs a section here, headed `## vX.Y.Z`, before its tag is pushed: the release
workflow publishes that section as the release notes and stops if it's missing.

## v1.5.0 — 2026-11-28
- Correction suggestions: when glucose has been above your target range for 30 minutes and isn't coming down, the Mac, Android and Windows apps notify you of a suggested correction dose, and the web page shows it. It's left out within 3 hours of logged rapid insulin or while carbs are still digesting. It uses the dose suggestion's own rules (insulin still active taken off, the dose cap, nothing when heading low), comes only for at least 1 u, and repeats at most every 2 hours. It's a suggestion to check before dosing, and each app has a switch for it. Settings are under `"correctionAlerts"` in `config.json` (see Correction suggestions in the README)

## v1.4.0 — 2026-11-28
- Safer dose suggestions: never more than a quarter of your usual daily dose or 15 u (marked "capped"); no insulin when you're below range or the forecast says you'll be low within 30 minutes; a rising trend no longer adds insulin on top of a meal still digesting or insulin still working; and the adjustment from past meals only moves the carb part, by at most 2 u up. All limits can be changed under `"dosing"` in `config.json` (see Dose safety limits in the README)
- The apps, web page and Windows tray show dose warnings more clearly, most serious first: heading low and below range in red, a capped dose and a missed long-acting dose in orange
- Long-acting checks (`GET /basal`): a warning on the dose suggestion when no long-acting has been logged for 26 hours, how glucose drifts while fasting, and long-acting's share of the daily dose. They only inform and don't change doses
- A low now has to last 15 minutes to count, so a single dip (such as lying on the sensor) no longer cuts learning short or marks a dose "too much"
- More accurate learning: corrections are only learned from with nothing else active, including ones after which glucose rose; the daily dose is the median of fully logged days; carb ratios stay within half and twice the rule of thumb and change gradually around 04:00, 11:00 and 16:00
- New settings in `config.json`: `"timezone"` for a server in another time zone than you (such as a cloud VM), `"insulin"` for Fiasp or Lyumjev, and `"targets"` for the web page's range and dose target
- Meals can be logged as slow (high fat or protein) on the web page, so their carbs count as absorbing over 5 hours
- Tests run on every push and pull request, and before each release

## v1.3.1 — 2026-11-26
- The server Mac no longer idle-sleeps while it's plugged in, so the server stays reachable after the display turns off (closing the lid still sleeps it, unless an external display is connected). Existing installs pick this up with this update
- Meal photos that are missing from disk (e.g. left on a previous Mac) are no longer offered to the apps and web page, and asking for one returns "not found" instead of an error

## v1.3.0 — 2026-11-24
- The server can use the Gemini API or any OpenAI-compatible API (Groq, a local Ollama model, OpenRouter, …) instead of Claude for photo carb estimates, the dose adjustment from past meals and weekly summaries, so it can run on a free cloud VM without a Claude subscription. Set it under `"ai"` in `config.json` (see AI providers in the README); Claude stays the default
- Gemini moves on from Gemini 3.8 Flash to 3.6 Flash and then 3.5 Flash-Lite while a model is overloaded or out of free quota, and busy answers are retried
- The apps and web page no longer name Claude ("Estimate carbs", "AI estimate"), and say when AI isn't set up on the server

## v1.2.3 — 2026-10-26
- The menu bar popup always fits its content: it no longer shows a transparent band above or below it after the content changed while it was closed (it's now a standard popover, like other menu bar apps)

## v1.2.2 — 2026-10-24
- The web page has the GlucoseBar icon as its favicon
- The web page's tab title shows the latest value and trend arrow (e.g. "123 → · Glucose"), or how old the reading is when it's more than 20 minutes old

## v1.2.1 — 2026-10-22
- The server isn't Mac-only: the README explains running it on Linux or Windows (password in `config.json`), and the apps' server settings no longer say it has to be a Mac
- The server stops with a clear message when the password is missing outside macOS, instead of failing to run the Keychain tool
- README screenshots of the Mac, Android and web apps

## v1.2.0 — 2026-10-22
- Android app: glucose in the status bar and a home screen widget, low/high/heading-low/no-data alerts (lows can break through Do Not Disturb), chart, stats, journal, meal/insulin/exercise logging with photo carb estimates, dose suggestions and the weekly summary. Install `GlucoseBar.apk` from the release; it updates itself

## v1.1.0 — 2026-10-21
- The suggested dose for a meal now allows for how the same food went before: Claude compares the meal with your last 90 days of meals, however you worded them ("half chicken (200g)" or "200g chicken"), and adjusts the formula's number for doses that ran high or low, with a one-line reason (kept between half and 1.5× the formula's number)

## v1.0.3 — 2026-10-21
- Check for Updates shows what's new in the latest release, with an Install button, instead of installing right away

## v1.0.2 — 2026-10-21
- Releases are built with Xcode 27, so the app looks the same as a local build (full-width chart range picker, current Settings layout)

## v1.0.1 — 2026-10-21
- Updates are also checked at login and whenever GlucoseBar opens, not only every 6 hours
- Settings → Server shows the version, with a Check for Updates button
- Windows tray menu: Check for updates

## v1.0.0 — 2026-10-21
First release.
- Installs from GitHub releases with one command on Mac and Windows, and updates itself every 6 hours
- The server only answers requests addressed to known host names and only accepts JSON changes, so other websites open in your browser can't read your data or add entries
- Includes everything so far: menu bar glucose with trend and forecast, alerts, meal, insulin and exercise log with Claude carb estimates, journal, meal scores, dose suggestions, exercise model, weekly summary, web page and Windows tray
