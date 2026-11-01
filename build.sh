#!/bin/sh
# Builds build/DroidHub.app, plus build/DroidHub.dmg with --dmg.
# SIGN_IDENTITY signs with Developer ID (hardened runtime). With NOTARY_KEY_ID,
# NOTARY_ISSUER_ID and NOTARY_KEY_P8 it also notarizes. Without them it signs ad hoc.
# The scrcpy server version must match the protocol in Mirror.swift.
set -e
cd "$(dirname "$0")"
SCRCPY=5.0.1
VERSION=$(cat version.txt)
JAR=".build/scrcpy-server-v$SCRCPY"
mkdir -p .build
[ -f "$JAR" ] || curl -fsSL -o "$JAR" "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY/scrcpy-server-v$SCRCPY"

swift build -c release
APP=build/DroidHub.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DroidHub "$APP/Contents/MacOS/"
cp "$JAR" "$APP/Contents/Resources/scrcpy-server"
cp -R .build/release/DroidHub_DroidHub.bundle "$APP/Contents/Resources/"

# Icon Composer icon with layers rendered by icon/icon.py. actool writes Assets.car,
# which macOS 26 needs to skip the gray squircle it puts around legacy icons, plus
# an AppIcon.icns fallback.
xcrun actool icon/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$(mktemp -d)/icon.plist" > /dev/null
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DroidHub</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.eduardo.droidhub</string>
    <key>CFBundleName</key><string>DroidHub</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>ScrcpyVersion</key><string>$SCRCPY</string>
</dict>
</plist>
EOF

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi

if [ -n "${SIGN_IDENTITY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ]; then
  KEY=$(mktemp)
  trap 'rm -f "$KEY"' EXIT  # the key must not outlive a failed notarization
  printf '%s' "$NOTARY_KEY_P8" > "$KEY"
  ditto -c -k --keepParent "$APP" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
  xcrun stapler staple "$APP"
  rm -f "$KEY" build/notarize.zip
fi

if [ "${1:-}" = "--dmg" ]; then
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname DroidHub -srcfolder "$STAGE" -ov -format UDZO build/DroidHub.dmg
  rm -rf "$STAGE"
fi
echo "$APP"
