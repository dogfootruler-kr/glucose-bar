#!/bin/bash
# Installs GlucoseBar from the latest GitHub release, and a launchd agent that installs
# newer releases at login, when the app opens and every 6 hours.
#   ./install.sh                 server + app on this Mac
#   ./install.sh --remote URL    app only, reading another Mac's server (e.g. over Tailscale)
#   ./install.sh --dev           server + app built from this checkout (skipped by the updater)
#   install.sh --update          what the updater runs: installs the latest release if it's newer
# Without a checkout:
#   curl -fsSL https://github.com/dogfootruler-kr/glucose-bar/releases/latest/download/install.sh | bash -s -- [--remote URL]
set -euo pipefail
REPO="dogfootruler-kr/glucose-bar"
SUPPORT="$HOME/Library/Application Support/freestyle-bar"
CODE="$SUPPORT/current"  # installed server code, this script and VERSION
VENV="$SUPPORT/venv"
CFG_DIR="$HOME/.config/freestyle-bar"
LABEL="co.dnk.freestyle-bar.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UPDATE_LABEL="co.dnk.freestyle-bar.update"
UPDATE_PLIST="$HOME/Library/LaunchAgents/$UPDATE_LABEL.plist"
APP="/Applications/GlucoseBar.app"

MODE="install"; REMOTE=""
case "${1:-}" in
  --remote) REMOTE="${2:?usage: ./install.sh --remote http://host:8765}" ;;
  --dev) MODE="dev" ;;
  --update) MODE="update" ;;
esac
# The server Mac is the one with the server agent (remote Macs only have the app).
if [ "$MODE" = "update" ]; then [ -f "$PLIST" ] && SERVER=1 || SERVER=0
else [ -z "$REMOTE" ] && SERVER=1 || SERVER=0; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

latest_tag() {
  curl -fsSI "https://github.com/$REPO/releases/latest" |
    awk -F/ 'tolower($1) ~ /^location:/ && $NF ~ /^v[0-9]/ { print $NF }' | tr -d '\r'
}

# Puts new files in place with mv, so a running copy of this script keeps reading the old one.
put() { cp -R "$1" "$TMP/put"; rm -rf "$2"; mv "$TMP/put" "$2"; }

install_app() {
  pkill -x GlucoseBar 2>/dev/null && sleep 1 || true
  put "$1" "$APP"
  open "$APP"
}

restart_server() {
  launchctl kickstart -k "gui/$UID/$LABEL" 2>/dev/null || true
}

install_release() {
  local tag="$1" base="https://github.com/$REPO/releases/download/$1"
  echo "Installing GlucoseBar $tag"
  mkdir -p "$CODE" "$TMP/rel"
  curl -fsSL -o "$TMP/rel/GlucoseBar.zip" "$base/GlucoseBar.zip"
  curl -fsSL -o "$TMP/rel/install.sh" "$base/install.sh"
  if [ "$SERVER" = 1 ]; then
    curl -fsSL "$base/server.tar.gz" | tar -xz -C "$TMP/rel"
    put "$TMP/rel/server" "$CODE/server"
  fi
  ditto -x -k "$TMP/rel/GlucoseBar.zip" "$TMP/rel"
  chmod +x "$TMP/rel/install.sh"
  put "$TMP/rel/install.sh" "$CODE/install.sh"
  echo "$tag" > "$CODE/VERSION"
  install_app "$TMP/rel/GlucoseBar.app"
}

install_dev() {
  local root; root="$(cd "$(dirname "$0")" && pwd)"
  [ -d "$root/app" ] || { echo "--dev needs a checkout of the repository"; exit 1; }
  "$root/app/bundle.sh" dev
  mkdir -p "$CODE"
  [ "$SERVER" = 1 ] && put "$root/server" "$CODE/server"
  put "$root/install.sh" "$CODE/install.sh"
  echo "dev" > "$CODE/VERSION"
  install_app "$root/app/.build/GlucoseBar.app"
}

setup_server() {
  # Credentials (password goes to the Keychain, never to disk)
  mkdir -p "$CFG_DIR"
  if [ ! -f "$CFG_DIR/config.json" ]; then
    read -rp "LibreLinkUp email: " EMAIL </dev/tty
    read -rsp "LibreLinkUp password: " PASS </dev/tty; echo
    security add-generic-password -U -s freestyle-bar -a "$EMAIL" -w "$PASS"
    printf '{"email": "%s"}\n' "$EMAIL" > "$CFG_DIR/config.json"
    chmod 600 "$CFG_DIR/config.json"
  fi
  # Python venv with the Claude Agent SDK, which uses your `claude` login
  [ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check claude-agent-sdk
  mkdir -p "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$VENV/bin/python</string><string>$CODE/server/libre_server.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/freestyle-bar.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/freestyle-bar.log</string>
</dict></plist>
PL
  load "$LABEL" "$PLIST"
}

write_updater_plist() {
  mkdir -p "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"
  cat > "$UPDATE_PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$UPDATE_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$CODE/install.sh</string><string>--update</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>21600</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/freestyle-bar-update.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/freestyle-bar-update.log</string>
</dict></plist>
PL
}

setup_updater() {
  write_updater_plist
  load "$UPDATE_LABEL" "$UPDATE_PLIST"
}

load() {
  launchctl bootout "gui/$UID/$1" 2>/dev/null || true
  for i in 1 2 3 4 5; do launchctl bootstrap "gui/$UID" "$2" 2>/dev/null && break; sleep 1; done
}

if [ "$MODE" = "update" ]; then
  current="$(cat "$CODE/VERSION" 2>/dev/null || true)"
  [ "$current" = "dev" ] && exit 0  # built from a checkout: leave it alone
  # Keep the agent's settings current; launchd reads them at the next login (reloading here
  # would stop this run).
  write_updater_plist
  tag="$(latest_tag || true)"
  [ -n "$tag" ] && [ "$tag" != "$current" ] || exit 0
  echo "$(date '+%F %T') $current -> $tag"
  install_release "$tag"
  [ "$SERVER" = 1 ] && restart_server
  exit 0
fi

[ -n "$REMOTE" ] && defaults write co.dnk.GlucoseBar serverURL "$REMOTE"
if [ "$MODE" = "dev" ]; then
  install_dev
else
  tag="$(latest_tag || true)"
  [ -n "$tag" ] || { echo "Could not find the latest release of $REPO"; exit 1; }
  install_release "$tag"
fi
if [ "$SERVER" = 1 ]; then setup_server; restart_server; fi
setup_updater
if [ "$SERVER" = 1 ]; then echo "Done. Logs: tail -f ~/Library/Logs/freestyle-bar.log"; else echo "Done. Reading from $REMOTE"; fi
echo "Updates install automatically at login, when the app opens and every 6 hours (log: ~/Library/Logs/freestyle-bar-update.log)."
echo "Add GlucoseBar to System Settings → General → Login Items to start it at login."
