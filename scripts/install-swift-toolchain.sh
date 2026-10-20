#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:?Usage: install-swift-toolchain.sh absolute-destination}"
if [[ "$destination" != /* || -e "$destination" ]]; then
    echo "Choose an absolute destination that does not exist." >&2
    exit 1
fi
version="$(cat .swift-version)"
checksums="$PWD/scripts/swift-toolchain.sha256"
staging="$(mktemp -d "${TMPDIR:-/tmp}/prumo-swift.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
curl --fail --location --retry 3 --output "$staging/toolchain.pkg" \
    "https://download.swift.org/swift-$version-release/xcode/swift-$version-RELEASE/swift-$version-RELEASE-osx.pkg"
(cd "$staging" && shasum -a 256 --check "$checksums")
pkgutil --check-signature "$staging/toolchain.pkg"
pkgutil --expand-full "$staging/toolchain.pkg" "$staging/expanded"
mkdir -p "$(dirname "$destination")"
mv "$staging/expanded/swift-$version-RELEASE-osx-package.pkg/Payload" "$destination"
"$destination/usr/bin/swift" --version
