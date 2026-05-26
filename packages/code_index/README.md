# Code Index MCP

A code-indexing MCP server that maintains a persistent, layered SQLite index of source files in a project. Designed for AI-assisted development workflows where an agent needs to explore and understand a codebase without reading every file into its context window.

## Purpose

The code index lets an agent ask cheap questions about a codebase — "what does this file do?", "what symbols are defined here?", "which files use this class?" — without reading raw source. The index is persistent across sessions and automatically detects when files on disk have changed.

## Database Location

The SQLite database is stored at:

```
[planner-data-root]/projects/[project-dir-name]/db/code_index.db
```

The `--planner-data-root` CLI argument controls where data lives. The database uses a clean-rebuild strategy: if the schema version on disk differs from the expected version, the database is discarded and rebuilt from scratch.

## Layered Information Model

Every indexed file holds data at multiple layers. Consumers pick the cheapest layer that answers their question.

| Layer | Name | Source | Typical tokens | When to use |
|------:|------|--------|---------------:|-------------|
| 0 | **Metadata** | Filesystem stat + hash | 30–60 | Listing files, filtering by type/size |
| 1 | **Short summary** | Haiku (LLM) | 20–40 | "What does this file do?" across many files |
| 2 | **Symbols / declarations** | Dart analyzer (Dart) or Haiku (other) | 100–400 | "What's defined here?", search by symbol |
| 3 | **Per-symbol summaries** | Haiku (LLM) | 200–800 | "What does each function do?" without reading source |
| 4 | **Public API** | Derived from layer 2 (filtered) | 50–200 | "What's the contract this file offers to callers?" |

Layer 5 is the raw file content — not stored in the index; use `filesystem read-file` as a fallback.

## Operations

### Scanning & Indexing

| Operation | Description |
|-----------|-------------|
| `auto-scan` | Walk the project tree, compare hashes, return an indexing plan. Supports `since` (mtime pre-filter) and `rebuild: true` (drop + recreate DB). |
| `auto-index` | Layer-aware indexing of a single file. Computes layer 0 + 2 deterministically for Dart; accepts LLM-provided `short_summary` (layer 1) and `symbol_summaries` (layer 3). |
| `diff` | Report changed/added/deleted files without producing a plan. |

### Reading

| Operation | Description |
|-----------|-------------|
| `get-file` | Get a single file's layered data. Default layers: `[0, 1, 4]`. Returns `needs_reindex` array for stale files. |
| `get-files` | Batched `get-file` for multiple paths. |
| `overview` | Compact listing of all indexed files with descriptions and export names. |

### Searching

| Operation | Description |
|-----------|-------------|
| `search` | Full-text search across file names, descriptions, exports, variables, and external symbols. BM25 ranking with prefix matching. |
| `usages` | Search external symbol usages by `symbol`, `module`, `source_path`, `dot_path_pattern`, `kind`, or `path_pattern`. |
| `dependents` | Find all files that import a given path. |
| `dependencies` | Get all imports for a file, classified as internal/external. |
| `search-annotations` | Search TODO/FIXME/HACK/NOTE/DEPRECATED annotations. |
| `stats` | Aggregate statistics about the index. |

### Utility

| Operation | Description |
|-----------|-------------|
| `is-allowed` | Check if a path is within the `code-index` allowed paths. |

## Cache-Discard Rebuild Flow

The code index uses a **clean-rebuild** strategy instead of schema migrations:

1. On startup, the MCP checks the `schema_version` stored in the database.
2. If the version differs from the expected version, the entire database file is deleted and recreated with the current schema.
3. All files then appear as "added" in the next `auto-scan`, triggering a full re-index.

This avoids migration complexity and guarantees schema consistency. The trade-off is a one-time re-index cost when the schema changes.

## Stale Detection

Every read operation (`get-file`, `get-files`) computes the file's XXH3 hash on disk and compares it to the stored hash. Changed files are reported in a `needs_reindex` array so the caller can decide whether to re-index them.

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

## External Symbol Usages (Dart)

For Dart files, the analyzer extracts all external symbol references and stores them in dot-path notation:

```
<module>.<source_path>.<symbol>
```

Examples:
- `flutter.material.Widget` — `Widget` from `package:flutter/material.dart`
- `dart.io.File` — `File` from `dart:io`

This enables queries like "which files use `Widget`?" via the `usages` operation.

## Usage

```bash
dart run packages/code_index/bin/code_index_mcp.dart \
  --project-dir=/path/to/project \
  --planner-data-root=/path/to/data
```

The server communicates over stdio using the Model Context Protocol (MCP).
