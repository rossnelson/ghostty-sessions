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

# macOS ties the Accessibility and Automation permissions to the signature. An
# ad-hoc signature changes on every build, so each rebuild would ask again. A
# stable local certificate keeps them. Order: GHOSTTY_SESSIONS_SIGN_IDENTITY,
# then a local "Sidebar Local Signing" certificate, then ad hoc.
identity="${GHOSTTY_SESSIONS_SIGN_IDENTITY:-}"
if [[ -z $identity ]]; then
  identity=$(security find-identity -p codesigning 2>/dev/null \
    | awk '/"Sidebar Local Signing"/ { print $2; exit }')
fi
codesign --force --sign "${identity:--}" --identifier dev.local.ghostty-sessions "$app"
[[ -n $identity ]] && echo "Signed with $identity" || echo "Signed ad hoc"
echo "Built $app"
