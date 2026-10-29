#!/bin/zsh
# Builds "VoiceNote Translator.app" into build/.
#
#   scripts/build-app.sh                 universal (Apple silicon + Intel) release build
#   scripts/build-app.sh --native        this Mac's architecture only (faster)
#   scripts/build-app.sh --install       also copy into /Applications (or ~/Applications)
#
# Signing: see the "Signing" block below (SIGN_IDENTITY, else Developer ID, else Apple Development, else ad-hoc).
set -euo pipefail
cd "${0:A:h}/.."

ARCHS=(--arch arm64 --arch x86_64)
INSTALL=0
for a in "$@"; do
  case $a in
    --native) ARCHS=() ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option $a"; exit 2 ;;
  esac
done

VERSION=$(cat VERSION)
NAME="VoiceNote Translator"
BUNDLE_ID=$(sed -n 's/.*bundleID = "\(.*\)".*/\1/p' Sources/VNTCore/Constants.swift)
APP="build/$NAME.app"

# The extension's version must match the app's.
if ! grep -q "\"version\": \"$VERSION\"" extension/manifest.json; then
  echo "extension/manifest.json version doesn't match VERSION ($VERSION)"; exit 1
fi

echo "▸ Compiling ($VERSION)"
swift build -c release ${ARCHS[@]} --product VoiceNoteTranslator
swift build -c release ${ARCHS[@]} --product vnt-host
BIN=$(swift build -c release ${ARCHS[@]} --show-bin-path)

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/VoiceNoteTranslator" "$APP/Contents/MacOS/"
cp "$BIN/vnt-host" "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
rsync -a --exclude '.DS_Store' extension/ "$APP/Contents/Resources/Extension/"
# Sparkle (automatic updates). Its XPC services are only needed by sandboxed
# apps, and this one isn't sandboxed, so they're left out.
rsync -a "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

# Updates are read from the latest GitHub release of the repo this is built
# from (FEED_URL overrides). Without a GitHub remote the app has no updater.
if [[ -z ${FEED_URL:-} ]]; then
  REPO=$(git remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#p')
  FEED_URL=${REPO:+https://github.com/$REPO/releases/latest/download/appcast.xml}
fi
UPDATE_KEY=$(cat Resources/update-public-key.txt)
echo "  update feed: ${FEED_URL:-none}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>VoiceNoteTranslator</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Open source under the MIT License.</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$UPDATE_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST

echo "▸ Signing"
# macOS ties permissions (Accessibility, access to other apps' data) to the
# app's signature. Ad-hoc signatures change with every build, so permissions
# would have to be granted again after each rebuild (and after every update).
# Use a real certificate when there is one: SIGN_IDENTITY if set, otherwise a
# Developer ID Application certificate (same signature as releases, so local
# builds and updates share permissions), otherwise Apple Development (free
# with any Apple ID in Xcode → Settings → Accounts).
IDENTITY=${SIGN_IDENTITY:-}
for kind in "Developer ID Application" "Apple Development"; do
  [[ -n $IDENTITY ]] && break
  IDENTITY=$(security find-identity -v -p codesigning | sed -n "s/.*\"\($kind: [^\"]*\)\".*/\1/p" | head -1)
done
if [[ -z $IDENTITY ]]; then
  IDENTITY=-
  echo "  ⚠ No signing certificate found; signing ad-hoc. macOS will ask for permissions again after every rebuild."
else
  echo "  using \"$IDENTITY\""
fi
OPTS=(--force --timestamp=none)
[[ $IDENTITY == "Developer ID Application"* ]] && OPTS=(--force --timestamp --options runtime)
codesign $OPTS --sign "$IDENTITY" "$APP/Contents/MacOS/vnt-host"
# Sparkle's helpers first, innermost out, then the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign $OPTS --sign "$IDENTITY" "$FW/Versions/B/Autoupdate"
codesign $OPTS --sign "$IDENTITY" "$FW/Versions/B/Updater.app"
codesign $OPTS --sign "$IDENTITY" "$FW"
codesign $OPTS --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

if (( INSTALL )); then
  DEST=/Applications
  [[ -w $DEST ]] || DEST=~/Applications
  mkdir -p "$DEST"
  pkill -x VoiceNoteTranslator 2>/dev/null || true
  rm -rf "$DEST/$NAME.app"
  cp -R "$APP" "$DEST/"
  echo "▸ Installed $DEST/$NAME.app"
fi
echo "✓ $APP"
