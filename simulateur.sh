#!/bin/zsh
# Lance l'app dans le simulateur iOS (iPhone 17 Pro) : serveur local + Safari du simulateur.
# Usage : ./simulateur.sh [chemin]   ex. ./simulateur.sh "index.html?spot=la_nord"
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
UDID=$(xcrun simctl list devices available | grep "iPhone 17 Pro (" | head -1 | grep -oE '[0-9A-F-]{36}')
[[ -z "$UDID" ]] && UDID=$(xcrun simctl list devices available | grep -i iphone | head -1 | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$UDID" 2>/dev/null
open -a Simulator --args -CurrentDeviceUDID "$UDID"
pgrep -f "http.server 8765" >/dev/null || (nohup .venv/bin/python -m http.server 8765 --directory output --bind :: >/dev/null 2>&1 &)
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
sleep 2
xcrun simctl openurl "$UDID" "http://localhost:8765/${1:-index.html}"
echo "App ouverte dans le simulateur. Dans Safari : Partager → « Sur l'écran d'accueil » pour la tester en plein écran."
