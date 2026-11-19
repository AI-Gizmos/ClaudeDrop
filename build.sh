#!/bin/zsh
# Builds ClaudeDrop.app into ./build and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ClaudeDrop.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target "$(uname -m)-apple-macos13.0" -o "$APP/Contents/MacOS/ClaudeDrop" src/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.claudedrop</string>
  <key>CFBundleName</key><string>ClaudeDrop</string>
  <key>CFBundleExecutable</key><string>ClaudeDrop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/ClaudeDrop.app
cp -R "$APP" ~/Applications/ClaudeDrop.app
echo "Installed ~/Applications/ClaudeDrop.app"
