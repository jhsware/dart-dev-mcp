## Unreleased

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
