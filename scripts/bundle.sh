#!/bin/bash
# Builds Ghostty Sessions.app into build/ and signs it ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
app="build/Ghostty Sessions.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/GhosttySessions "$app/Contents/MacOS/GhosttySessions"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ghostty Sessions</string>
  <key>CFBundleDisplayName</key><string>Ghostty Sessions</string>
  <key>CFBundleIdentifier</key><string>dev.local.ghostty-sessions</string>
  <key>CFBundleExecutable</key><string>GhosttySessions</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Ghostty Sessions lists your Ghostty tabs, focuses them, and opens new ones.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "Built $app"
