#!/bin/zsh
# Makes a drag-and-drop disk image from build/VoiceNote Translator.app:
# the app on the left, an arrow, and a link to Applications on the right.
#
#   scripts/make-dmg.sh [output.dmg]
#
# Laying out the window uses Finder via AppleScript. If macOS doesn't allow that
# (Automation permission), the image still works, just without the custom layout.
set -euo pipefail
cd "${0:A:h}/.."

NAME="VoiceNote Translator"
VERSION=$(cat VERSION)
APP="build/$NAME.app"
OUT=${1:-"dist/VoiceNote-Translator-$VERSION.dmg"}
[[ -d $APP ]] || { echo "Build the app first (scripts/build-app.sh)"; exit 1; }

WORK=$(mktemp -d)
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background" "$(dirname "$OUT")"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Drawing background"
swift scripts/make-dmg-background.swift "$WORK/bg1x.png" 1
swift scripts/make-dmg-background.swift "$WORK/bg2x.png" 2
# One multi-resolution TIFF, so the background is sharp on Retina screens.
tiffutil -cathidpicheck "$WORK/bg1x.png" "$WORK/bg2x.png" -out "$STAGE/.background/background.tiff" >/dev/null

echo "▸ Creating image"
VOLNAME="$NAME $VERSION"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | sed -n 's#.*\(/Volumes/.*\)#\1#p' | tail -1)

echo "▸ Laying out the window"
if ! osascript <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$NAME.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
then
  echo "  ⚠ Finder layout skipped (allow Automation for your terminal to get the custom window)"
fi

# Hide the background folder, give the volume the app's icon, and finish.
SetFile -a V "$MOUNT/.background" 2>/dev/null || true
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns" && SetFile -c icnC "$MOUNT/.VolumeIcon.icns" 2>/dev/null && SetFile -a C "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

echo "▸ Compressing"
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"

# Sign the image too when a real certificate is available.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}
[[ -n $IDENTITY ]] && codesign --force --sign "$IDENTITY" "$OUT" 2>/dev/null || true
echo "✓ $OUT"
