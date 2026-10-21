#!/bin/bash
# Builds app/.build/GlucoseBar.app (used by install.sh --dev and the release workflow).
#   app/bundle.sh VERSION
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-dev}"
(cd "$DIR" && swift build -c release)
APP="$DIR/.build/GlucoseBar.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$DIR/.build/release/GlucoseBar" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>co.dnk.GlucoseBar</string>
  <key>CFBundleName</key><string>GlucoseBar</string>
  <key>CFBundleExecutable</key><string>GlucoseBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
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
