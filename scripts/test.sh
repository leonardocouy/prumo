#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH:/opt/homebrew/bin"
swift format lint --strict --recursive Sources/Prumo Tests Package.swift scripts/make-icon.swift
cargo fmt --manifest-path core/Cargo.toml --all -- --check
bash scripts/build.sh
cargo test --locked --manifest-path core/Cargo.toml
cargo clippy --locked --manifest-path core/Cargo.toml --all-targets -- -D warnings
swift build --arch arm64
binary_directory="$(swift build --arch arm64 --show-bin-path)"
swiftc -parse-as-library -swift-version 6 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -I "$binary_directory" -I Sources/PrumoCoreFFI \
    Sources/Prumo/Settings.swift Sources/Prumo/Services.swift Sources/Prumo/SkillActions.swift Tests/NativeChecks.swift \
    "$binary_directory/PrumoCore.o" \
    core/target/aarch64-apple-darwin/release/libprumo_core.a \
    -o .build/native-checks
.build/native-checks
python3 -m unittest discover -s Tests -p 'test_release_secrets.py'
