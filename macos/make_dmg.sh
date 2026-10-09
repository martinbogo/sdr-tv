#!/bin/bash
# Packages build/SDR TV.app (from build.sh) as a drag-to-Applications disk image:
#   build/SDR-TV-<version>-macOS-arm64.dmg
# Lays out the window with Finder; without Finder access (no GUI session) the image still works,
# just without the background and icon positions.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/SDR TV.app"
[ -d "$APP" ] || { echo "Build the app first: macos/build.sh"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
NAME="SDR TV $VERSION"
DMG="build/SDR-TV-$VERSION-macOS-arm64.dmg"
STAGE=build/dmg
RW=build/dmg-rw.dmg
rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/SDR TV.app"
ln -s /Applications "$STAGE/Applications"
swift make_dmg_background.swift build/bg1.png 1
swift make_dmg_background.swift build/bg2.png 2
tiffutil -cathidpicheck build/bg1.png build/bg2.png -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
rm -f build/bg1.png build/bg2.png

hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 200m "$RW"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')
osascript <<AS || echo "note: Finder layout skipped"
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 760, 480}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "SDR TV.app" of container window to {150, 170}
        set position of item "Applications" of container window to {410, 170}
        update without registering applications
        delay 1
        close
    end tell
end tell
AS
sync
hdiutil detach -quiet "$DEV" || { sleep 3; hdiutil detach -force "$DEV"; }
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$STAGE" "$RW"
echo "Built $DMG"
