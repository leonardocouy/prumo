#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "Build Prumo on an Apple Silicon Mac. Only macOS ARM64 is supported." >&2
    exit 1
fi
if ! command -v cargo-about >/dev/null; then
    echo "Install cargo-about: cargo install cargo-about --version 0.9.2 --locked --features cli" >&2
    exit 1
fi
cargo build --locked --manifest-path core/Cargo.toml --release --features bindgen
(cd core && cargo run --locked --release --features bindgen --bin uniffi-bindgen -- generate --library target/aarch64-apple-darwin/release/libprumo_core.dylib --language swift --out-dir ../.build/bindings)
mkdir -p Sources/PrumoCore Sources/PrumoCoreFFI
cp .build/bindings/PrumoCore.swift Sources/PrumoCore/PrumoCore.swift
cp .build/bindings/PrumoCoreFFI.h Sources/PrumoCoreFFI/PrumoCoreFFI.h
cp .build/bindings/PrumoCoreFFI.modulemap Sources/PrumoCoreFFI/module.modulemap
swift build -c release --arch arm64
bundle="dist/Prumo.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
binary_directory="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$binary_directory/Prumo" "$bundle/Contents/MacOS/Prumo"
cp scripts/Info.plist "$bundle/Contents/Info.plist"
cp scripts/Prumo.icns "$bundle/Contents/Resources/Prumo.icns"
cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
cargo about generate --locked --all-features --manifest-path core/Cargo.toml --config about.toml --fail scripts/licenses.hbs > "$bundle/Contents/Resources/ThirdPartyLicenses.html"
codesign --force --sign - "$bundle"
bash scripts/verify-bundle.sh "$bundle"
echo "Built $PWD/$bundle"
