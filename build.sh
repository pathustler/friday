#!/bin/bash
# Usage: ./build.sh          -> builds FRIDAY.app in this folder
#        ./build.sh install  -> also copies to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=FRIDAY.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/FRIDAY" "$APP/Contents/MacOS/FRIDAY"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.friday.app</string>
  <key>CFBundleName</key><string>F.R.I.D.A.Y</string>
  <key>CFBundleDisplayName</key><string>F.R.I.D.A.Y</string>
  <key>CFBundleExecutable</key><string>FRIDAY</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>F.R.I.D.A.Y listens for the wake word “Friday” and your voice requests. Speech is processed on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>F.R.I.D.A.Y turns your speech into text on this Mac so you can talk to it.</string>
  <key>NSContactsUsageDescription</key><string>F.R.I.D.A.Y shows people from your Contacts in search and in chat, and the AI can look them up for you.</string>
  <key>NSAppleEventsUsageDescription</key><string>FRIDAY uses AppleScript for commands like Toggle Dark Mode and Empty Trash.</string>
</dict></plist>
PLIST
# local speech recognition (whisper.cpp): bundle the server if it has been built (see vendor/whisper.cpp)
WHISPER=vendor/whisper.cpp/build/bin/whisper-server
if [ -x "$WHISPER" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$WHISPER" "$APP/Contents/Resources/whisper-server"
fi
codesign --force --deep --sign - "$APP"
echo "Built $APP"
if [ "${1:-}" = "install" ]; then
  pkill -x FRIDAY 2>/dev/null || true
  rm -rf /Applications/$APP
  cp -R "$APP" /Applications/
  open /Applications/$APP
  echo "Installed to /Applications and launched. Press ⌥Space."
fi
