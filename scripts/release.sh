#!/bin/bash
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
: "${RELEASE_TAG:?RELEASE_TAG is required.}"
: "${APPLE_CERTIFICATE:?APPLE_CERTIFICATE is required.}"
: "${APPLE_CERTIFICATE_PASSWORD:?APPLE_CERTIFICATE_PASSWORD is required.}"
: "${APPLE_ID:?APPLE_ID is required.}"
: "${APPLE_ID_PASSWORD:?APPLE_ID_PASSWORD is required.}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required.}"
: "${RUNNER_TEMP:?Use a GitHub-hosted macOS runner.}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
if [[ "$RELEASE_TAG" != "v$version" ]]; then
    echo "Release tag must match the app version: v$version" >&2
    exit 1
fi
staging="$(mktemp -d "$RUNNER_TEMP/prumo-signing.XXXXXX")"
export SIGNING_KEYCHAIN="$staging/signing.keychain-db"
original_keychains=()
keychain_paths="$(security list-keychains -d user | python3 -c 'import shlex, sys; print("\n".join(shlex.split(sys.stdin.read())))')"
while IFS= read -r keychain; do
    if [[ -n "$keychain" ]]; then
        original_keychains+=("$keychain")
    fi
done <<< "$keychain_paths"
cleanup() {
    security list-keychains -d user -s ${original_keychains[@]+"${original_keychains[@]}"} \
        || echo "Could not restore the original keychain search list." >&2
    if [[ -f "$SIGNING_KEYCHAIN" ]]; then
        security delete-keychain "$SIGNING_KEYCHAIN" || echo "Could not remove the temporary signing keychain." >&2
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
umask 077
python3 - "$staging/certificate.p12" <<'PY'
import base64
import os
from pathlib import Path
import sys
encoded = ''.join(os.environ['APPLE_CERTIFICATE'].split())
Path(sys.argv[1]).write_bytes(base64.b64decode(encoded, validate=True))
PY
keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN"
security list-keychains -d user -s "$SIGNING_KEYCHAIN" ${original_keychains[@]+"${original_keychains[@]}"}
security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN"
security import "$staging/certificate.p12" -k "$SIGNING_KEYCHAIN" \
    -P "$APPLE_CERTIFICATE_PASSWORD" -t agg -f pkcs12 -T /usr/bin/codesign
rm "$staging/certificate.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$keychain_password" "$SIGNING_KEYCHAIN" > /dev/null
curl --fail --silent --show-error --location --proto '=https' \
    https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer --output "$staging/AppleG2.cer"
printf '%s  %s\n' f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a \
    "$staging/AppleG2.cer" | shasum -a 256 --check
security verify-cert -c "$staging/AppleG2.cer" -p basic
python3 - "$SIGNING_KEYCHAIN" "$staging/AppleG2.cer" <<'PY'
import base64
from pathlib import Path
import re
import subprocess
import sys
keychain, certificate = sys.argv[1:]
result = subprocess.run(['security', 'find-certificate', '-a', '-p', keychain],
                        check=True, capture_output=True, text=True).stdout
installed = [base64.b64decode(value) for value in re.findall(
    r'-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----', result, re.S)]
if Path(certificate).read_bytes() not in installed:
    subprocess.run(['security', 'import', certificate, '-k', keychain], check=True)
else:
    print('Verified Apple G2 intermediate is already included in the signing backup.')
PY
SIGNING_IDENTITY="$(python3 - "$SIGNING_KEYCHAIN" "$APPLE_TEAM_ID" <<'PY'
import re
import subprocess
import sys
result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning', sys.argv[1]],
                        check=True, capture_output=True, text=True).stdout
identities = re.findall(r'\) ([A-F0-9]{40}) "Developer ID Application: .*? \('
                        + re.escape(sys.argv[2]) + r'\)"', result)
if len(identities) != 1:
    raise SystemExit('Expected exactly one valid Developer ID Application identity for APPLE_TEAM_ID.')
print(identities[0])
PY
)"
export SIGNING_IDENTITY
export NOTARY_PROFILE=Prumo-Release
xcrun notarytool store-credentials "$NOTARY_PROFILE" --keychain "$SIGNING_KEYCHAIN" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_ID_PASSWORD"
unset APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_ID_PASSWORD keychain_password
bash scripts/package.sh
