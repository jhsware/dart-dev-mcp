# Code Index MCP

A code-indexing MCP server that maintains a persistent, layered SQLite index of source files in a project. Designed for AI-assisted development workflows where an agent needs to explore and understand a codebase without reading every file into its context window.

## Purpose

The code index lets an agent ask cheap questions about a codebase — "what does this file do?", "what symbols are defined here?", "where is this symbol declared?", "which files use this class?" — without reading raw source. The index is persistent across sessions and automatically detects when files on disk have changed (SHA-256).

## Storage Location

The store is a standalone directory tree, independent of the planner. Each project gets its own data directory:

```
[data-root]/[basename]-[sha8]/code_index.db
```

- `[data-root]` defaults to `~/.code-index` and is overridable with `--data-root=PATH`.
- `[basename]` is the project directory's name; `[sha8]` is the first 8 hex chars of the SHA-256 of the canonical (symlink-resolved) project path — so two projects that share a basename still get distinct directories.
- `[data-root]/registry.json` lists every known project with `created_at` / `last_opened_at`; each data directory holds a `meta.json` marker that pins it to its project (guarding against hash-prefix collisions).

The database uses a clean-rebuild strategy: if the `schema_version` on disk differs from the expected version, the database is discarded and rebuilt from scratch (no migrations).

## Layered Information Model

Every indexed file holds data at multiple layers. Consumers pick the cheapest layer that answers their question.

| Layer | Name | Source | When to use |
|------:|------|--------|-------------|
| 0 | **Metadata** | Filesystem stat + SHA-256 | Listing files, filtering by type/size |
| 1 | **Summary + tags** | Indexing agent (LLM) | "What does this file do?" across many files |
| 2 | **Symbols / declarations** | Dart analyzer (Dart) or agent (other) | "What's defined here?", search by symbol |
| 3 | **Per-symbol summaries** | Indexing agent (LLM) | "What does each function do?" without reading source |
| 4 | **Public API** | Derived from layer 2 (filtered to `public`) | "What's the contract this file offers to callers?" |

Raw file content is not stored — use `filesystem read-file` (optionally with the line range from `find-symbol`) as a fallback.

## Operations

A single MCP tool `code-index`, multiplexed by `operation`. `project_dir` is required on every call.

### Scanning & Indexing

| Operation | Parameters | Description |
|-----------|------------|-------------|
| `scan` | `directories`, `extensions`, `since`, `rebuild`, `remove_deleted`, `verify` | Walk the tree, detect added/changed/deleted files (SHA-256), remove deleted rows, and return a language-aware indexing `plan`. Merges the old `auto-scan` + `diff`. |
| `index-files` | `files[]`, `refresh_dependents` | Batched write of 1..N records. Dart layer 2 is computed by the warm analyzer; other files carry agent-supplied structure. After the batch, dependents of changed Dart files are re-resolved unless `refresh_dependents: false`. Only `path` is required per record. |

### Reading

| Operation | Parameters | Description |
|-----------|------------|-------------|
| `get-file` | `path`, `layers` | One file's layered data. Default `layers: [0, 1, 4]`. Returns a `needs_reindex` array. |
| `get-files` | `paths[]`, `layers` | Batched `get-file` with aggregated `needs_reindex`. |
| `overview` | `path_pattern`, `file_type`, `language`, `limit` | Compact listing: per file `path`, `summary`, `tags`, `line_count`, public symbol names. |

### Searching

| Operation | Parameters | Description |
|-----------|------------|-------------|
| `search` | `query`, `file_type`, `language`, `path_pattern`, `tag`, `symbol_name`, `symbol_kind`, `import_pattern`, `limit` | FTS5 across names, paths, summaries, tags, symbols, and reference dot-paths (OR + prefix + BM25) plus AND filters. Falls back to LIKE on malformed queries. |
| `find-symbol` | `name`, `match` (`exact`\|`prefix`), `kind`, `visibility`, `path_pattern`, `limit` | Resolve a declaration to its file + line range — the "jump to definition" op that enables partial reads. |
| `references` | `symbol`, `module`, `source_path`, `dot_path_pattern`, `kind`, `resolution` (`resolved`\|`declared`), `path_pattern`, `limit` | Which files use a symbol, in dot-path notation. Ordered by usage count. |
| `dependents` | `path` | Files that import a given path. |
| `dependencies` | `path` | A file's imports, classified `internal` / `external`. |
| `annotations` | `kind`, `message_pattern`, `path_pattern`, `file_type`, `limit` | TODO/FIXME/HACK/NOTE/DEPRECATED queries with `by_kind` counts. |
| `stats` | `limit` | Aggregate counts, tag cloud, freshness summary. |

### Utility

| Operation | Parameters | Description |
|-----------|------------|-------------|
| `project-info` | — | Data dir, db path, `registry.json` entry, schema version, row counts, last scan. |
| `is-allowed` | `path` | Check if a path is within the `code-index` allowed paths (works without a database). |

## SHA-256 Change Detection

`scan` walks the tree with an mtime + size short-circuit, then hashes candidates with SHA-256 to classify files as `added`, `changed`, `deleted`, or unchanged. `verify: true` forces full hashing even when mtime + size are unchanged. Every read operation also surfaces a `needs_reindex` array by comparing the on-disk hash to the stored one, so consumers can decide whether to re-index.

## Cache-Discard Rebuild Flow

The code index uses a **clean-rebuild** strategy instead of schema migrations:

1. On open, the MCP checks the `schema_version` stored in the database (`PRAGMA user_version`).
2. If it differs from the expected version, the entire database file (and WAL/SHM sidecars) is deleted and recreated with the current schema.
3. All files then appear as `added` in the next `scan`, triggering a full re-index.

`scan` with `rebuild: true` forces this discard-and-recreate on demand.

## Allowed Paths Configuration

The `jhsware-code.yaml` file in each project directory controls which paths the code index can access:

```yaml
code-index:
  allowed_paths:
    - lib
    - test
    - bin
    - pubspec.yaml
```

- Operations on paths outside the allowed list return `out_of_scope` responses.
- If `jhsware-code.yaml` is missing, the full project root is accessible (matching `filesystem` and `git` behavior).
- Use `is-allowed` to check before calling other operations.

## External Symbol References (Dart)

For Dart files, the analyzer extracts external symbol references and stores them in dot-path notation:

```
<module>.<source_path>.<symbol>
```

Examples:
- `flutter.material.Widget` — `Widget` from `package:flutter/material.dart`
- `dart.io.File` — `File` from `dart:io`

This enables queries like "which files use `Widget`?" via the `references` operation. Because dot-paths are also indexed into FTS, a `search` for `material` finds every file importing from `flutter.material.*`.

## Usage

```bash
dart run packages/code_index/bin/code_index_mcp.dart \
  --project-dir=/path/to/project \
  [--project-dir=/path/to/another] \
  [--data-root=/custom/store]
```

Options:

- `--project-dir=PATH` — a project directory (required, repeatable).
- `--data-root=PATH` — root of the code-index store (optional, default `~/.code-index`).
- `--help`, `-h` — show usage.

The server communicates over stdio using the Model Context Protocol (MCP).
