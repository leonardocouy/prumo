#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$version" ]]; then
    echo "Release tag must match the app version: v$version" >&2
    exit 1
fi
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Prumo.app/Contents/Info.plist)"
bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/Prumo.app/Contents/Info.plist)"
source_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' scripts/Info.plist)"
if [[ "$bundle_version" != "$version" || "$bundle_build" != "$source_build" ]]; then
    echo "App version or build does not match scripts/Info.plist. Build the app before packaging." >&2
    exit 1
fi
verification=""
keychain=()
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
    keychain=(--keychain "$SIGNING_KEYCHAIN")
fi
if [[ -n "${RELEASE_TAG:-}" ]]; then
    : "${SIGNING_IDENTITY:?A tag release requires SIGNING_IDENTITY.}"
    : "${NOTARY_PROFILE:?A tag release requires NOTARY_PROFILE.}"
    : "${APPLE_TEAM_ID:?A tag release requires APPLE_TEAM_ID.}"
    verification=--notarized
fi
bash scripts/verify-bundle.sh dist/Prumo.app
output="$PWD/dist/release"
rm -rf "$output"
mkdir -p "$output"
archive="Prumo-$version-macos-arm64"
staging="$(mktemp -d "$PWD/dist/package.XXXXXX")"
mounted=""
cleanup() {
    if [[ -n "$mounted" ]]; then
        hdiutil detach "$mounted" || true
    fi
    rm -rf "$staging"
}
trap cleanup EXIT

notarize() {
    local payload="$1" result="$staging/notarization.json"
    local submission
    if ! xcrun notarytool submit "$payload" --keychain-profile "$NOTARY_PROFILE" \
        ${keychain[@]+"${keychain[@]}"} --wait --timeout 15m --output-format json > "$result"; then
        cat "$result" >&2
        echo "Notarization did not complete successfully. No release will be published." >&2
        return 1
    fi
    submission="$(python3 - "$result" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1]))
print(result['id'])
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept the submission: ' + str(result.get('status')))
PY
)"
    echo "Apple accepted submission $submission"
}

if [[ -n "${RELEASE_TAG:-}" ]]; then
    codesign --force --options runtime --timestamp ${keychain[@]+"${keychain[@]}"} --sign "$SIGNING_IDENTITY" dist/Prumo.app
    bash scripts/verify-bundle.sh dist/Prumo.app --signed
    ditto -c -k --sequesterRsrc --keepParent dist/Prumo.app "$staging/submission.zip"
    notarize "$staging/submission.zip"
    xcrun stapler staple dist/Prumo.app
    bash scripts/verify-bundle.sh dist/Prumo.app "$verification"
fi
ditto -c -k --sequesterRsrc --keepParent dist/Prumo.app "$output/$archive.zip"
ditto -x -k "$output/$archive.zip" "$staging/extracted"
bash scripts/verify-bundle.sh "$staging/extracted/Prumo.app" "$verification"
mkdir -p "$staging/dmg"
ditto dist/Prumo.app "$staging/dmg/Prumo.app"
ln -s /Applications "$staging/dmg/Applications"
hdiutil create -volname Prumo -srcfolder "$staging/dmg" -ov -format UDZO "$output/$archive.dmg"
if [[ -n "${RELEASE_TAG:-}" ]]; then
    codesign --force --timestamp ${keychain[@]+"${keychain[@]}"} --sign "$SIGNING_IDENTITY" "$output/$archive.dmg"
    codesign --verify --strict --verbose=2 "$output/$archive.dmg"
    notarize "$output/$archive.dmg"
    xcrun stapler staple "$output/$archive.dmg"
    xcrun stapler validate "$output/$archive.dmg"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$output/$archive.dmg"
fi
hdiutil verify "$output/$archive.dmg"
mkdir -p "$staging/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$staging/mounted" "$output/$archive.dmg"
mounted="$staging/mounted"
bash scripts/verify-bundle.sh "$mounted/Prumo.app" "$verification"
hdiutil detach "$mounted"
mounted=""
if [[ -n "${RELEASE_TAG:-}" ]]; then
    cp .github/RELEASE_NOTES.md "$output/RELEASE_NOTES.md"
else
    printf '%s\n' 'Prumo CI build for Apple Silicon.' \
        'This artifact uses ad hoc signing and is not notarized.' \
        'Use a signed, notarized tag release for distribution.' > "$output/RELEASE_NOTES.md"
fi
(cd "$output" && shasum -a 256 "$archive.zip" "$archive.dmg" > SHA256SUMS.txt)
echo "Packaged $output/$archive.zip and $archive.dmg"
