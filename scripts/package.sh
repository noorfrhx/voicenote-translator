#!/bin/zsh
# Makes the release files in dist/:
#   VoiceNote-Translator-<version>.dmg              drag-and-drop installer
#   VoiceNote-Translator-<version>-mac.zip          the app, zipped
#   VoiceNote-Translator-Connector-<version>.zip    the browser extension
#   SHA256SUMS.txt
#
# With SIGN_IDENTITY ("Developer ID Application: …") and NOTARY_PROFILE (a
# `xcrun notarytool store-credentials` profile) set, the app and the disk image
# are notarized and stapled, so they open without warnings on any Mac.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(cat VERSION)
NAME="VoiceNote Translator"

scripts/build-app.sh
mkdir -p dist
rm -f dist/*

notarize() {
  [[ -n ${NOTARY_PROFILE:-} && ${SIGN_IDENTITY:-} == "Developer ID Application"* ]] || return 0
  echo "▸ Notarizing $1"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

APP_ZIP="dist/VoiceNote-Translator-$VERSION-mac.zip"
ditto -c -k --keepParent "build/$NAME.app" "$APP_ZIP"
if notarize "$APP_ZIP" && [[ -n ${NOTARY_PROFILE:-} ]]; then
  xcrun stapler staple "build/$NAME.app"
  rm "$APP_ZIP"
  ditto -c -k --keepParent "build/$NAME.app" "$APP_ZIP"
fi

DMG="dist/VoiceNote-Translator-$VERSION.dmg"
scripts/make-dmg.sh "$DMG"
notarize "$DMG" && [[ -n ${NOTARY_PROFILE:-} ]] && xcrun stapler staple "$DMG" || true

(cd extension && zip -qr "../dist/VoiceNote-Translator-Connector-$VERSION.zip" . -x '.DS_Store')
(cd dist && shasum -a 256 *.dmg *.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
