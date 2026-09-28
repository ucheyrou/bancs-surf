#!/bin/zsh
# Compile l'app et la lance dans le simulateur iPhone 17 Pro (serveur de données local inclus).
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
UDID=$(xcrun simctl list devices available | grep "iPhone 17 Pro (" | head -1 | grep -oE '[0-9A-F-]{36}')
./sync_data.sh >/dev/null
xcodegen generate >/dev/null
xcodebuild -project BancsSurf.xcodeproj -scheme BancsSurf -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
xcrun simctl boot "$UDID" 2>/dev/null; open -a Simulator --args -CurrentDeviceUDID "$UDID"
pgrep -f "http.server 8765" >/dev/null || (cd .. && nohup .venv/bin/python -m http.server 8765 --directory output --bind :: >/dev/null 2>&1 &)
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/BancsSurf.app
xcrun simctl terminate "$UDID" fr.ulysse.BancsSurf 2>/dev/null
xcrun simctl launch "$UDID" fr.ulysse.BancsSurf
