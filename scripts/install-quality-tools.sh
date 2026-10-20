#!/bin/bash
set -euo pipefail
destination="${1:?Usage: install-quality-tools.sh absolute-bin-directory}"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 || "$destination" != /* || -e "$destination" ]]; then
    echo "Use Linux x86_64 and an absolute destination that does not exist." >&2
    exit 1
fi
mkdir -p "$destination"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

install_tool() {
    local url="$1" checksum="$2" member="$3" strip="$4"
    curl --fail --location --retry 3 --output "$staging/archive" "$url"
    printf '%s  %s\n' "$checksum" "$staging/archive" | sha256sum --check
    tar -xf "$staging/archive" -C "$destination" --strip-components="$strip" "$member"
}

install_tool \
    https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz \
    8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 \
    actionlint 0
install_tool \
    https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz \
    8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 \
    shellcheck-v0.11.0/shellcheck 1
install_tool \
    https://github.com/rustsec/rustsec/releases/download/cargo-audit/v0.22.2/cargo-audit-x86_64-unknown-linux-musl-v0.22.2.tgz \
    7fb9497f8594b389e5fce5ef9b92db08432996895b2e0c5a0167a69ed445c428 \
    cargo-audit-x86_64-unknown-linux-musl-v0.22.2/cargo-audit 1
