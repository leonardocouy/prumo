# Contribute

Build on an Apple Silicon Mac with macOS 15 or later. Follow [BUILDING.md](BUILDING.md).

Keep changes focused. Describe the user-visible behavior and include relevant verification results.
For interface changes, include a screenshot made with synthetic data.
For parser changes, use synthetic session records. Do not commit real conversation history.

Run `bash scripts/test.sh` before opening a pull request.
Run `bash scripts/package.sh` for changes to builds, resources, or release packaging.
Keep generated UniFFI bindings, local databases, credentials, and build output out of Git.

Report security concerns privately as described in [SECURITY.md](SECURITY.md).
Contributions are provided under the repository's MIT license. Third-party components retain their own licenses.
