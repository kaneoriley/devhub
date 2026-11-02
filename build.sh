#!/bin/sh
# Builds an ad hoc signed build/DevHub.app for local use.
# The scrcpy server version must match the protocol in Mirror.swift.
set -e
if [ "$#" -ne 0 ]; then
  echo "Usage: ./build.sh" >&2
  exit 2
fi
cd "$(dirname "$0")"
SCRCPY=5.0.1
JAR=".build/scrcpy-server-v$SCRCPY"
mkdir -p .build
[ -f "$JAR" ] || curl -fsSL -o "$JAR" "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY/scrcpy-server-v$SCRCPY"

swift build -c release
APP=build/DevHub.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DevHub "$APP/Contents/MacOS/"
cp "$JAR" "$APP/Contents/Resources/scrcpy-server"
cp -R .build/release/DevHub_DevHub.bundle "$APP/Contents/Resources/"

# Icon Composer icon with layers rendered by icon/icon.py and icon/apple.swift. actool writes Assets.car,
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
    <key>CFBundleExecutable</key><string>DevHub</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.kaneoriley.devhub</string>
    <key>CFBundleName</key><string>DevHub</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>ScrcpyVersion</key><string>$SCRCPY</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "$APP"
