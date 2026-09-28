#!/bin/zsh
# Compile, signe et installe l'app sur l'iPhone branché (à relancer tous les 7 jours avec un compte gratuit).
# Le build vit hors iCloud : codesign refuse les attributs étendus que la synchro pose sur le Bureau.
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD=~/Library/Developer/Xcode/DerivedData/BancsSurf-iphone
APP=$BUILD/Build/Products/Release-iphoneos/BancsSurf.app
DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && / (connected|available) / {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) print $i}' | head -1)
[[ -z $DEVICE ]] && { echo "Aucun iPhone connecté : brancher, déverrouiller, « Se fier »."; exit 1; }
./sync_data.sh >/dev/null
xcodegen generate >/dev/null
xcodebuild -project BancsSurf.xcodeproj -scheme BancsSurf -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath $BUILD -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD" || exit 1
xcrun devicectl device install app --device $DEVICE $APP 2>&1 | grep -E "bundleID|ERROR"
xcrun devicectl device process launch --device $DEVICE fr.ulysse.BancsSurf 2>&1 | grep -E "Launched|ERROR|trusted"
