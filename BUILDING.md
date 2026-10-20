# Build Prumo

## Requirements

- An Apple Silicon Mac with macOS 15 or later.
- Apple's Swift Command Line Tools, or a stable Xcode installation, for the macOS SDK.
- Swift 6.4.1. The compiler version is pinned in `.swift-version`.
- Rustup. `rust-toolchain.toml` selects Rust 1.99.1 and the `aarch64-apple-darwin` target.
- `cargo-about` 0.9.2, including its CLI feature.

Install the license report tool:

```sh
cargo install cargo-about --version 0.9.2 --locked --features cli
```

No environment files or credentials are required to build. The first build downloads Cargo dependencies.
There are no external Swift package dependencies. SwiftUI and AppKit come from Apple's SDK.

If your SDK installation includes an older Swift compiler, download the pinned compiler into the project:

```sh
bash scripts/install-swift-toolchain.sh "$PWD/.toolchains/swift"
export PATH="$PWD/.toolchains/swift/usr/bin:$PATH"
```

This verifies the official Swift.org package checksum and Apple signature, then extracts it without changing system settings.
It does not install Xcode, change your shell profile, or accept a license agreement.
An existing Swift 6.4.1 installation also works.

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
Set `RELEASE_TAG` only for a signed, notarized release. It must match the version in `scripts/Info.plist`.
For example, `RELEASE_TAG=v0.3.3` requires version `0.3.3` and the signing configuration below.

## GitHub Actions

Pull requests and pushes to `main` build, test, and package the app on a `macos-26` Apple Silicon runner.
The workflow uses the stable Xcode 26.6 SDK, the official Swift 6.4.1 compiler, and the pinned Rust toolchain.
Action versions are pinned by commit. Dependabot checks Cargo and GitHub Actions each week.

A pushed `v*` tag also publishes a prerelease after the build, signing, and notarization checks pass.
Only the publishing job receives repository write permission. Pull requests and branch builds do not receive signing credentials.
The release job checks SHA-256 sums before uploading the ZIP and DMG.

A separate Ubuntu job checks workflow syntax with actionlint 1.7.12, shell scripts with ShellCheck 0.11.0, and vulnerabilities with cargo-audit 0.22.2.
These tools are downloaded from upstream releases and checked against pinned SHA-256 digests.
The job also runs weekly. Scheduled runs skip app builds and packaging.

Before building, Swift's bundled formatter checks handwritten files and rejects forced unwraps, casts, and forced `try`.
Rustfmt checks Rust formatting before the behavior tests and Clippy.
Generated UniFFI bindings are excluded from Swift formatting.

To apply Swift formatting locally:

```sh
swift format format --in-place --recursive Sources/Prumo Tests Package.swift scripts/make-icon.swift
```

Local builds and ordinary CI artifacts use ad hoc signing. They are not notarized.
Starting with v0.3.2, public tag releases require Developer ID signing and Apple notarization.
Missing credentials, rejected submissions, missing tickets, or failed verification stop publication.

## Signed releases

Configure these GitHub Actions secrets in the Prumo repository:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | Base64-encoded `.p12` containing a Developer ID Application certificate and its private key. |
| `APPLE_CERTIFICATE_PASSWORD` | Password used to encrypt that `.p12`. |
| `APPLE_ID` | Apple Account email for notarization. |
| `APPLE_ID_PASSWORD` | Apple app-specific password for notarization. |
| `APPLE_TEAM_ID` | Developer team that owns the signing certificate. |

These names match Claudometer's Apple credential names. Prumo generates its temporary keychain password on each run.
Credentials remain outside Git and release assets. Share them only through GitHub's encrypted Actions secrets.
The Apple Account must belong to the signing team. App Store publication is not required.

The setup helper prompts for both passwords privately and asks before uploading the five credentials:

```sh
python3 scripts/configure-release-secrets.py \
  --repo OWNER/REPOSITORY \
  --certificate /path/to/Developer-ID.p12 \
  --apple-id YOUR_APPLE_ACCOUNT_EMAIL \
  --team-id YOUR_TEAM_ID
```

Run it in an interactive terminal with an authenticated GitHub CLI. It does not store passwords in project files.
The first prompt uses the `.p12` export password. The second uses Apple's app-specific password.
The helper validates `.p12` exports with macOS's bundled `/usr/bin/openssl`, independent of Homebrew tools on `PATH`.

The tag build runs `bash scripts/release.sh` after the ordinary build and tests.
It imports the identity into a temporary keychain, checks the expected team, and validates notarization credentials.
The keychain, imported certificate, and credential profile are removed when the release script exits.
The script verifies Apple's G2 intermediate certificate against a pinned checksum and Apple's trusted root before import.

Packaging signs the app with hardened runtime and a secure timestamp, then submits it to Apple.
After acceptance, it staples the app ticket and creates the final ZIP from that app.
It then signs, notarizes, and staples the DMG separately.
The extracted ZIP and mounted DMG must pass signature, ticket, architecture, resource, and Gatekeeper checks.
Checksums are calculated after stapling completes. The publishing job receives only the verified release files.

To package a release locally with an existing signing identity and saved notarization profile:

```sh
RELEASE_TAG=v0.3.3 \
SIGNING_IDENTITY="YOUR_DEVELOPER_ID_CERTIFICATE_SHA1" \
NOTARY_PROFILE="YOUR_SAVED_NOTARY_PROFILE" \
APPLE_TEAM_ID="YOUR_TEAM_ID" \
bash scripts/package.sh
```

Build first with `bash scripts/build.sh`. Packaging checks that the tag matches the source and bundle versions.
Use `SIGNING_KEYCHAIN` only when the identity and notarization profile are stored in a separate keychain.
Do not put passwords in commands, repository files, or issue comments.

For a manual verification of a notarized bundle:

```sh
APPLE_TEAM_ID="YOUR_TEAM_ID" bash scripts/verify-bundle.sh dist/Prumo.app --notarized
```

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
