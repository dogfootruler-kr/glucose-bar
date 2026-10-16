# GlucoseBar

FreeStyle Libre glucose in the macOS menu bar, without Android/ADB.

Phone (Libre app) → LibreView cloud → LibreLinkUp API → `server/libre_server.py` (localhost:8765) → `GlucoseBar.app`

## Setup
1. Install **LibreLinkUp** on your phone and create a *separate* account (a follower account).
2. In the FreeStyle Libre app: Menu → Share / Connected Apps → LibreLinkUp → add that email. Accept the invite in LibreLinkUp, and accept any terms there.
3. `./install.sh`, then enter the follower account's email and password. The password is stored in the Keychain.

Logs: `~/Library/Logs/freestyle-bar.log` · API: `curl localhost:8765/glucose`
