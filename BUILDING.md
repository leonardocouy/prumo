# Build Prumo

## Requirements

- An Apple Silicon Mac with macOS 15 or later.
- Apple's Swift Command Line Tools, or a stable Xcode installation.
- Rustup. `rust-toolchain.toml` selects Rust 1.99.1 and the `aarch64-apple-darwin` target.
- `cargo-about` 0.9.2, including its CLI feature.

Install the license report tool:

```sh
cargo install cargo-about --version 0.9.2 --locked --features cli
```

No environment files or credentials are required to build. The first build downloads Cargo dependencies.
There are no external Swift package dependencies. SwiftUI and AppKit come from Apple's SDK.

## Build and test

```sh
bash scripts/test.sh
```

This builds Rust, generates UniFFI Swift bindings, builds the app, and creates `dist/Prumo.app`.
It runs Rust behavior tests, Clippy, and native Swift behavior checks.
The Swift checks work with Command Line Tools and do not require XCTest.

To build without running the behavior checks:

```sh
bash scripts/build.sh
open dist/Prumo.app
```

The build uses the checked-in Cargo lockfile. UniFFI bindings are generated and are not stored in Git.
The Rust library is linked statically. The app has no separate Rust runtime library.

The bundle check verifies its signature, ARM64 architecture, macOS 15 deployment target, system libraries, and allowed resources.
The bundle includes the app license and a generated third-party license report.

## Package

```sh
bash scripts/package.sh
```

This creates a ZIP, a DMG, and `SHA256SUMS.txt` under `dist/release`.
The script extracts and checks the ZIP before packaging completes. It also verifies the DMG.
Set `RELEASE_TAG=v0.3.0` to enforce a match with the version in `scripts/Info.plist`.

## GitHub Actions

Pull requests and pushes to `main` build, test, and package the app on a `macos-26` Apple Silicon runner.
The workflow selects stable Xcode 26.6 and the pinned Rust toolchain.
Action versions are pinned by commit. Dependabot checks Cargo and GitHub Actions each week.

A pushed `v*` tag also publishes a prerelease after the build passes.
Only that publishing job receives repository write permission. Builds do not need signing credentials.
The release job checks SHA-256 sums before uploading the ZIP and DMG.

Local and automated builds use ad hoc signing. They are not Developer ID signed or notarized.
Public distribution without Gatekeeper prompts requires Developer ID signing and Apple's notarization service.

## Update dependencies

Check current stable versions on crates.io before changing `core/Cargo.toml`.
Keep the UniFFI library and binding generator at the same version.

```sh
cargo update --manifest-path core/Cargo.toml
cargo audit --file core/Cargo.lock
bash scripts/test.sh
bash scripts/package.sh
```

On October 20, 2026, direct dependencies matched the latest stable crates.io releases.
The lockfile uses the latest compatible transitive versions. Upstream constraints can prevent newer, incompatible versions.

The audit reported no known vulnerabilities and one maintenance warning: `basic-toml` is unmaintained (`RUSTSEC-2026-0374`).
It is used by Askama's compile-time macros through the current UniFFI binding generator.
No advisory is suppressed. Recheck this chain when updating UniFFI.
