## Unreleased

### BREAKING: jhsware_code naming convention (packages, tools, binaries)

All packages now follow one convention based on the `jhsware_code` prefix.
Dart packages are `jhsware_code_<tool>` (snake_case), MCP tool names keep
their simple, easy-to-type dash form (`dart-runner`, `code-index`), compiled
binaries are `jhsware-code-<tool>`, and MCP server keys are
`jhsware_code_<tool>`.

**Package renames (pubspec `name:`):**
- `dart_dev_mcp` (root) → `jhsware_code`
- `filesystem_mcp` → `jhsware_code_filesystem`
- `git_mcp` → `jhsware_code_git`
- `dart_runner_mcp` → `jhsware_code_dart_runner`
- `flutter_runner_mcp` → `jhsware_code_flutter_runner`
- `fetch_mcp` → `jhsware_code_fetch`
- `planner_mcp` → `jhsware_code_planner`
- `code_index_mcp` → `jhsware_code_code_index`
- `apple_mail_mcp` → `jhsware_code_apple_mail`

**Tool names (dash form kept):**
- Tool names stay simple with dashes: `filesystem`, `git`, `planner`, `fetch`,
  `dart-runner`, `flutter-runner`, `code-index`, `apple-mail`,
  `fetch-and-transform`.
- `fetch_links` → `fetch-links` to match the dash convention.

**Binary renames** (rebuild + reinstall required):
- `file-edit-mcp` → `jhsware-code-filesystem`, `git-mcp` → `jhsware-code-git`,
  `dart-runner-mcp` → `jhsware-code-dart-runner`, `flutter-runner-mcp` →
  `jhsware-code-flutter-runner`, `fetch-mcp` → `jhsware-code-fetch`,
  `planner-mcp` → `jhsware-code-planner`, `code-index-mcp` →
  `jhsware-code-code-index`, `apple-mail-mcp` → `jhsware-code-apple-mail`.
- `apple_mail_mcp` is now part of the standard build.
- The installer package is `bin/jhsware-code-installer.pkg`.

**Entrypoint rename:** `packages/filesystem/bin/file_edit_mcp.dart` →
`packages/filesystem/bin/filesystem_mcp.dart` (a deprecated forwarder remains).

**Backwards compatible project config:** the permission file is now
`jhsware_code.yaml`, but the legacy `jhsware-code.yaml` name is still accepted
(preferred name wins when both exist). Config keys are matched with hyphens
normalised to underscores, so `code-index:` and `code_index:` both address the
`code-index` tool. Existing project permission files need no changes.

**Not renamed on purpose:** the code-index data root stays `~/.code-index`
(existing stores keep working), and operation names (e.g. `read-file`,
`branch-create`) keep their hyphenated form.

### BREAKING: planner is now a remote client (planner_remote → planner)

The `planner` MCP no longer opens a local `planner.db`. It is now a thin client
that proxies every operation to a separate **planner_server** over HTTPS.

- Package `planner_remote_mcp` renamed to `planner_mcp` (binary `planner-mcp`);
  the old local SQLite `planner` package was removed.
- Requires a planner_server URL and a service token (or an mTLS client cert):
  `--server-url` / `PLANNER_SERVER_URL` and `--token` / `PLANNER_SERVER_TOKEN`,
  plus optional `--ca-cert`, `--client-cert` / `--client-key`, and `--insecure`.
- `--planner-data-root` is no longer used by the planner (still used by code-index).
- Issue a service token on the planner_server host:
  `planner_server token issue --name <label> --kind mcp`.

### BREAKING: code-index rewrite (layered storage, MCP-driven invalidation)

**Removed operations:**
- `index-file` — replaced by `auto-index` with layer-aware parameters
- `show-file` — replaced by `get-file` with selectable layers
- `file-summary` — replaced by `get-file` with `layers: [0, 1]`

**New operations:**
- `auto-scan` — walk the project tree, compare hashes, return a structured indexing plan. Supports `since` (mtime pre-filter) and `rebuild: true` (clean rebuild).
- `get-file` — retrieve a single file's layered data (layers 0–4). Default: `[0, 1, 4]`. Includes `needs_reindex` stale detection.
- `get-files` — batched version of `get-file` for multiple paths.
- `usages` — search external symbol usages by symbol, module, dot-path pattern, or kind.
- `is-allowed` — check whether a path is inside the `code-index` allowed paths.

**Changed operations:**
- `auto-index` — now layer-aware; accepts `layers`, `short_summary`, `symbol_summaries`. Computes layer 0 + 2 deterministically for Dart files via `package:analyzer`.
- `search` — now also matches against external symbol usages via FTS.

**Other changes:**
- Database uses clean-rebuild semantics instead of schema migrations. If the on-disk schema version differs, the DB is discarded and rebuilt.
- Added `package:analyzer` dependency for deterministic Dart parsing (replaces regex-based `dart_parser.dart`).
- External symbol usages stored in dot-path notation (`module.source_path.symbol`) for cross-reference queries.
- Layered information model: metadata (0), short summary (1), symbols (2), per-symbol summaries (3), public API (4).
- `jhsware-code.yaml` allowed-path enforcement extended to all operations. Out-of-scope paths return structured `out_of_scope` responses.

## 0.1.0

- Initial version.
