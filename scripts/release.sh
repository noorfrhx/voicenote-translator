#!/bin/zsh
# Builds the release files and publishes them as a GitHub release for the
# version in VERSION. Release notes come from docs/releases/v<version>.md.
#
#   scripts/release.sh            publish (tags the current commit as v<version>)
#   scripts/release.sh --draft    create a draft release instead
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(cat VERSION)
TAG="v$VERSION"
NOTES="docs/releases/$TAG.md"
DRAFT=()
[[ ${1:-} == "--draft" ]] && DRAFT=(--draft)

[[ -f $NOTES ]] || { echo "Write $NOTES first."; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first."; exit 1; }
gh release view "$TAG" >/dev/null 2>&1 && { echo "$TAG is already released. Bump VERSION."; exit 1; }

scripts/package.sh
git tag -a "$TAG" -m "VoiceNote Translator $VERSION" 2>/dev/null || true
git push origin "$TAG"
gh release create "$TAG" ${DRAFT[@]} --title "VoiceNote Translator $VERSION" --notes-file "$NOTES" \
  dist/*.dmg dist/SHA256SUMS.txt
