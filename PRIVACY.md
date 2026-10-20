# Privacy and local data

Prumo reads the Codex and Claude Code data folders you configure.
Original session files remain the source of truth. Indexing does not change them.

The app stores searchable conversation text in `~/Library/Application Support/Prumo/Library.sqlite`.
It creates its default data directory with owner-only access. Settings are stored in UserDefaults.
An explicit `PRUMO_DATA_DIR` override selects another cache directory. Existing override directories keep their permissions.

The cache can contain private code, messages, and file paths from your conversations.
Keep it outside shared or public folders. Close the app before deleting the cache directory.
The next refresh rebuilds it from the configured session folders.

## Network use

Search, passage retrieval, and skills browsing run locally. The app has no analytics, billing, or cloud synchronization service.

**Answer with Codex** sends your question and selected excerpts through your installed Codex CLI.
The CLI's service processes that content under its own account and privacy settings.
The app uses existing CLI authentication. It does not store an API key.
The answer command ignores user configuration and rules, uses an ephemeral session, and requests a read-only sandbox.

Continuing a session opens the original agent in Terminal. That agent then operates under its own permissions and settings.

## Skills changes

Reading a skill does not change it. Saving an edit changes its `SKILL.md` file.
Link and Unlink change symbolic links in configured skill folders.
Move to Trash moves the selected editable folder and removes matching direct links.
The review screen lists affected paths before bulk changes.

Usage counts are derived from supported events in indexed session history.
They are incomplete when history is missing or unsupported. No recorded use does not prove that a skill was never used.
Added dates come from folder creation metadata and are approximate.

## Public repository and downloads

The source repository excludes session files, databases, credentials, environment files, build output, and local review records.
App bundles contain only the executable, icon, metadata, signature, and license notices.
Issue reports and screenshots can expose session text or paths. Review them before sharing.
