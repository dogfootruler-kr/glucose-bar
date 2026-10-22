# Changelog

Each release needs a section here, headed `## vX.Y.Z`, before its tag is pushed: the release
workflow publishes that section as the release notes and stops if it's missing.

## v1.2.0 — unreleased
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
