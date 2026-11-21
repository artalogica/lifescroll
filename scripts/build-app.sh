#!/bin/bash
# Builds Lifescroll and wraps it in an app bundle at build/Lifescroll.app.
# A menu bar app needs a real bundle: notifications and Screen Recording both depend on it.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Lifescroll.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/Lifescroll" "$APP/Contents/MacOS/Lifescroll"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>local.lifescroll.Lifescroll</string>
  <key>CFBundleName</key>
  <string>Lifescroll</string>
  <key>CFBundleDisplayName</key>
  <string>Lifescroll</string>
  <key>CFBundleExecutable</key>
  <string>Lifescroll</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. macOS ties Screen Recording, Accessibility and Keychain access to the signature,
# so each rebuild asks for them again until the app is signed with a real developer identity.
codesign --force --sign - "$APP"

echo "Built $APP"
