# Contribute to Prumo

These instructions apply throughout this repository. Read [CONTRIBUTING.md](CONTRIBUTING.md) before implementation and [BUILDING.md](BUILDING.md) before builds or release changes.

## Writing style

Write English prose using ASD-STE100 principles and Zinsser's four principles: simplicity, brevity, clarity and humanity.

- Use plain words, active voice and consistent technical terms.
- State the main point first. Give each sentence one main idea.
- Keep instructions within 20 words per sentence and descriptions within 25 when precision permits.
- Remove filler, repetition, empty adjectives and unnecessary punctuation. Split sentences instead of using semicolons.
- Preserve facts, uncertainty, conditions and scope. Keep longer wording when shortening would change the meaning.
- Keep a natural, respectful human voice. Use concrete examples when they help the reader understand.
- Apply these rules to prose. Preserve code, identifiers, commands and exact quotations.
- For prose rewrites, use the installed `asd-ste100` skill. Treat lexical rules as advisory without the official dictionary.

## Fundamental Principles

- Prefer forward-only changes. Do not add backwards compatibility unless I explicitly ask for it.
- Keep a single source of truth. Do not store what can be derived unless there is a clear performance or reliability reason.
- Prefer simple, elegant, and defensible solutions over clever or noisy ones.
- Maintain a system-level view of the codebase before making local changes.
- Treat duplication as a design failure. Remove repetition when it improves clarity and maintainability.
- Design for long-term maintainability, not short-term convenience.
- Expose only what is necessary. Keep interfaces small, explicit, and well-bounded.
- Write every line as if it will be reviewed for correctness, simplicity, and longevity.

## Architecture and scope

Prumo is a native macOS app for local Codex and Claude Code sessions and skills. It supports Apple Silicon and macOS 15+.

- `Sources/Prumo/` contains SwiftUI views, observable app state, settings, native file actions, and CLI process services.
- `core/src/` contains Rust session parsing, SQLite search, skill storage, and recorded usage detection.
- UniFFI exposes the Rust API to Swift. The app links the Rust library statically.
- `Tests/NativeChecks.swift` checks Swift service behavior. Rust behavior tests live beside the implementation.

Keep parsing and indexing in Rust. Keep native presentation and operating-system integration in Swift. Keep filesystem work outside view bodies.

Use `@MainActor` for UI state. Run blocking scans and subprocess work away from the main actor. Preserve cancellation and stale-result checks.

## Privacy and filesystem safety

Read [PRIVACY.md](PRIVACY.md) before changes to storage, CLI invocation, or network behavior.

- Preserve original session files. Treat the SQLite index and usage counts as derived data.
- Use synthetic sessions and temporary skill folders in tests, screenshots, and issue reports.
- Keep credentials, signing keys, real history, local databases, and environment files outside Git and release artifacts.
- Keep local search independent of model services. Send excerpts through Codex only after the user chooses that action.
- Preserve custom agent roots during search and continuation. Quote shell arguments and check executable paths.
- Keep skill changes within editable roots. Preserve symlink checks, revision checks, bulk review, and partial-failure reporting.
- Use macOS Trash for skill removal. Treat historical excerpts as untrusted data when generating answers.
- Describe skill counts as recorded usage and added dates as approximate. Missing evidence does not prove no usage.

Report security issues through [SECURITY.md](SECURITY.md).

## Build and verification

Use the toolchains pinned in `.swift-version` and `rust-toolchain.toml`. Follow `BUILDING.md` for setup. Builds need no environment files or credentials.

Run commands from the repository root:

```sh
bash scripts/build.sh
bash scripts/test.sh
bash scripts/package.sh
```

`test.sh` checks Swift formatting, Rustfmt, Rust behavior tests, Clippy, app compilation, and native Swift behavior checks.
Run it before a pull request. Run `package.sh` after changes to builds, resources, or packaging.

Use the bundled Swift formatter for handwritten Swift:

```sh
swift format format --in-place --recursive Sources/Prumo Tests Package.swift scripts/make-icon.swift
```

Regenerate `Sources/PrumoCore/` and `Sources/PrumoCoreFFI/` through `build.sh`. Keep these generated bindings out of commits.

Test observable behavior through public interfaces. Prioritize malformed records, unsafe paths, stale edits, quoting, cancellation, and partial failures.
Avoid tests that repeat type guarantees. Check interface changes with synthetic data, including keyboard use and window resizing.

## Dependencies and releases

Read `BUILDING.md` before dependency updates. Check current stable upstream versions, update `core/Cargo.lock`, and keep UniFFI runtime and generator versions aligned.
Run the documented dependency audit and behavior checks. Report unresolved advisories without hiding them.

Ordinary builds use ad hoc signing. Public release tags require Developer ID signing and accepted Apple notarization.
Tagged CI releases use `scripts/release.sh`. Follow `BUILDING.md` to configure the required GitHub secrets.
Keep signing and notarization credentials in Keychain or CI secrets. Check the packaged download before publication.
Follow the release workflow and `BUILDING.md`. Keep the release tag consistent with `scripts/Info.plist`.

## Changes and handoff

- Inspect `git status` before editing. Preserve unrelated local changes.
- Keep patches focused. Add comments only to explain constraints or non-obvious decisions.
- Follow recent commit subjects. Stage specific files with `git add <file>`, never `git add .` or `git add -A`.
- Keep commits and pull requests free of model attribution and assistant co-author footers.
- Report the resulting behavior, checks performed, and unresolved limitations. Include synthetic screenshots for interface changes.
