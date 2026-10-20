#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$version" ]]; then
    echo "Release tag must match the app version: v$version" >&2
    exit 1
fi
bash scripts/verify-bundle.sh dist/Prumo.app
output="$PWD/dist/release"
rm -rf "$output"
mkdir -p "$output"
archive="Prumo-$version-macos-arm64"
staging="$(mktemp -d "$PWD/dist/package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto -c -k --sequesterRsrc --keepParent dist/Prumo.app "$output/$archive.zip"
ditto -x -k "$output/$archive.zip" "$staging/extracted"
bash scripts/verify-bundle.sh "$staging/extracted/Prumo.app"
mkdir -p "$staging/dmg"
ditto dist/Prumo.app "$staging/dmg/Prumo.app"
ln -s /Applications "$staging/dmg/Applications"
hdiutil create -volname Prumo -srcfolder "$staging/dmg" -ov -format UDZO "$output/$archive.dmg"
hdiutil verify "$output/$archive.dmg"
cp .github/RELEASE_NOTES.md "$output/RELEASE_NOTES.md"
(cd "$output" && shasum -a 256 "$archive.zip" "$archive.dmg" > SHA256SUMS.txt)
echo "Packaged $output/$archive.zip and $archive.dmg"
