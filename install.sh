#!/bin/bash
# Installs the LibreLinkUp bridge (launchd agent) and GlucoseBar.app.
#   ./install.sh                 server + app on this Mac
#   ./install.sh --remote URL    app only, reading another Mac's server (e.g. over Tailscale)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
REMOTE=""
if [ "${1:-}" = "--remote" ]; then
  REMOTE="${2:?usage: ./install.sh --remote http://host:8765}"
fi
CFG_DIR="$HOME/.config/freestyle-bar"
LABEL="co.dnk.freestyle-bar.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -n "$REMOTE" ]; then
  defaults write co.dnk.GlucoseBar serverURL "$REMOTE"
else
# 1. Credentials (password goes to the Keychain, never to disk)
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG_DIR/config.json" ]; then
  read -rp "LibreLinkUp email: " EMAIL
  read -rsp "LibreLinkUp password: " PASS; echo
  security add-generic-password -U -s freestyle-bar -a "$EMAIL" -w "$PASS"
  printf '{"email": "%s"}\n' "$EMAIL" > "$CFG_DIR/config.json"
  chmod 600 "$CFG_DIR/config.json"
fi

# 2. Server as a launchd agent (Python venv with the Claude Agent SDK, which uses your `claude` login)
if [ ! -x "$ROOT/.venv/bin/python" ]; then
  python3 -m venv "$ROOT/.venv"
fi
"$ROOT/.venv/bin/pip" install -q --disable-pip-version-check claude-agent-sdk
mkdir -p "$HOME/Library/Logs"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$ROOT/.venv/bin/python</string><string>$ROOT/server/libre_server.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/freestyle-bar.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/freestyle-bar.log</string>
</dict></plist>
PL
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
for i in 1 2 3 4 5; do launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null && break; sleep 1; done
fi

# 3. Menu bar app
(cd "$ROOT/app" && swift build -c release)
APP="/Applications/GlucoseBar.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/app/.build/release/GlucoseBar" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>co.dnk.GlucoseBar</string>
  <key>CFBundleName</key><string>GlucoseBar</string>
  <key>CFBundleExecutable</key><string>GlucoseBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSExceptionDomains</key><dict>
      <key>ts.net</key><dict>
        <key>NSIncludesSubdomains</key><true/>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
      </dict>
    </dict>
  </dict>
</dict></plist>
PL
codesign --force --sign - "$APP"
pkill -x GlucoseBar 2>/dev/null && sleep 1 || true
open "$APP"
if [ -n "$REMOTE" ]; then echo "Done. Reading from $REMOTE"; else echo "Done. Logs: tail -f ~/Library/Logs/freestyle-bar.log"; fi
echo "Add GlucoseBar to System Settings → General → Login Items to start it at login."
