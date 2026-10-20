#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
bash scripts/build.sh
cargo test --locked --manifest-path core/Cargo.toml
cargo clippy --locked --manifest-path core/Cargo.toml --all-targets -- -D warnings
swift build --arch arm64
binary_directory="$(swift build --arch arm64 --show-bin-path)"
swiftc -parse-as-library -swift-version 6 \
    -I "$binary_directory/Modules" -I Sources/PrumoCoreFFI \
    Sources/Prumo/Settings.swift Sources/Prumo/Services.swift Sources/Prumo/SkillActions.swift Tests/NativeChecks.swift \
    "$binary_directory/PrumoCore.build/PrumoCore.swift.o" \
    core/target/aarch64-apple-darwin/release/libprumo_core.a \
    -o .build/native-checks
.build/native-checks
