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

# macOS ties Screen Recording, Accessibility and Keychain access to the app's signature.
#
# Signed with a certificate, the signature is "this bundle id, signed by this certificate", which is
# the same for every build, so permissions granted once keep working after a rebuild.
# Signed ad-hoc, the signature is a hash of the binary, which changes on every build, so macOS
# treats each rebuild as a new app and the permissions have to be granted again.
#
# The certificate is one you make yourself in Keychain Access (see the README). It is looked up by
# name; set LIFESCROLL_SIGN_IDENTITY to use a different one, such as an Apple Development identity.
IDENTITY="${LIFESCROLL_SIGN_IDENTITY:-Lifescroll Dev}"

if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with \"$IDENTITY\". Permissions carry over between builds."
else
  codesign --force --sign - "$APP"
  echo "No signing certificate named \"$IDENTITY\" found, so this build is signed ad-hoc."
  echo "macOS will ask for Screen Recording, Accessibility and Keychain access again."
  echo "To stop that, create the certificate once: see \"Keeping permissions across rebuilds\" in the README."
fi

echo "Built $APP"
