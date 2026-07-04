# Changelog

## 1.0.0 — v2 rewrite

Complete rewrite of the code-index MCP server (backlog item 567debdc).

### Storage

- Standalone store at `~/.code-index` (overridable with `--data-root`),
  independent of the planner. Each project gets `[basename]-[sha8]/code_index.db`,
  keyed by the SHA-256 of the canonical project path so shared basenames stay
  distinct.
- `registry.json` tracks known projects; a per-directory `meta.json` marker
  guards against hash-prefix collisions.
- Clean-rebuild strategy: a `schema_version` mismatch discards and recreates the
  database instead of migrating.

### Change detection

- SHA-256 content hashing with an mtime + size short-circuit classifies files as
  `added` / `changed` / `deleted` / unchanged.
- Every read operation surfaces a `needs_reindex` array by comparing the on-disk
  hash to the stored one, so consumers decide when to re-index.

### Extraction (warm-analyzer hybrid)

- Dart layer 2 (symbols, imports, references, annotations) is computed by the MCP
  via a warm analyzer with exact line ranges and resolved external references in
  dot-path notation (`<module>.<source_path>.<symbol>`, `resolution: "resolved"`).
- Non-Dart structure is supplied by the indexing agent; agent-declared references
  are normalized to the same dot-path shape (`resolution: "declared"`).
- Re-indexing a changed Dart file re-resolves the references of its direct
  dependents (`refresh_dependents`, reported as `dependents_refreshed`).

### Layered model

- Layer 0 metadata, layer 1 summary + **semantic tags**, layer 2 symbols /
  imports / references / annotations, layer 3 per-symbol summaries, layer 4 public
  API (derived from layer 2). Tags feed FTS so concept searches match even when
  the code uses different terminology.

### Operation surface

- `scan` (merges the former `auto-scan` + `diff`) returns a language-aware
  indexing `plan`; `index-files` performs batched writes (replaces per-file
  `auto-index`).
- Reads: `get-file`, `get-files`, `overview`.
- Search: `search` (FTS5), `find-symbol`, `references` (replaces `usages`),
  `dependents`, `dependencies`, `annotations`, `stats`.
- Utility: `project-info`, `is-allowed`.

### LLM-side artifacts

- Rewrote the `code-index` skill (token-lean reader guide, P1–P6 query patterns)
  and the `code-index-agent` writer (batched, layer-scoped, dot-path-safe).
