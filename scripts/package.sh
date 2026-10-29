#!/bin/zsh
# Makes the release files in dist/:
#   VoiceNote-Translator-<version>.dmg   drag-and-drop installer (the app includes the browser extension)
#   appcast.xml                          update feed for the app's automatic updates (Sparkle)
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

notarizing() { [[ -n ${NOTARY_PROFILE:-} && ${SIGN_IDENTITY:-} == "Developer ID Application"* ]]; }

# Notarize the app itself first, so the copy inside the disk image carries its
# own ticket and opens offline too. Apple takes a zip for that; it isn't kept.
if notarizing; then
  echo "▸ Notarizing the app"
  ditto -c -k --keepParent "build/$NAME.app" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  rm build/notarize.zip
  xcrun stapler staple "build/$NAME.app"
fi

DMG="dist/VoiceNote-Translator-$VERSION.dmg"
scripts/make-dmg.sh "$DMG"

if notarizing; then
  echo "▸ Notarizing the disk image"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# The update feed. Each entry is signed with the update key in your Keychain
# (created with Sparkle's generate_keys --account voicenote-translator); the
# app only installs updates signed with it. The release notes come from
# docs/releases/v<version>.md, placed next to the DMG under the same name.
# SKIP_APPCAST=1 skips this (CI has no update key).
REPO=$(git remote get-url origin | sed -nE 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#p')
if [[ -n $REPO && -z ${SKIP_APPCAST:-} ]]; then
  echo "▸ Writing update feed"
  FEED=$(mktemp -d)
  cp "$DMG" "$FEED/"
  if [[ -f docs/releases/v$VERSION.md ]]; then cp "docs/releases/v$VERSION.md" "$FEED/VoiceNote-Translator-$VERSION.md"; fi
  .build/artifacts/sparkle/Sparkle/bin/generate_appcast --account voicenote-translator \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --embed-release-notes -o dist/appcast.xml "$FEED"
  rm -rf "$FEED"
fi

(cd dist && shasum -a 256 *.dmg > SHA256SUMS.txt && cat SHA256SUMS.txt)
