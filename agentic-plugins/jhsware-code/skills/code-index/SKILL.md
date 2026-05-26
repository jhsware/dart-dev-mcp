---
name: code-index
description: Query the layered code index for token-efficient codebase exploration and search.
allowed-tools: filesystem, code-index
model: haiku
context: fork
agent: code-index-agent
---

## Purpose

The code-index is a persistent, layered database of file metadata so you can explore and search the codebase without reading full source files. Querying the index costs ~30–400 tokens per file vs ~500–5000+ tokens for reading source.

This skill is the **consumer-side** guide — it teaches you how to **query** the index. The indexing workflow (how to *write* to the index) lives in `code-index-agent`.

## Layered Information Model

Every indexed file stores five layers. Always start with the cheapest layer that answers your question.

| Layer | Name | Tokens | What it tells you |
|------:|------|-------:|-------------------|
| 0 | Metadata | ~30–60 | Path, file type, size, hash, staleness |
| 1 | Short summary | ~20–40 | One-sentence description of what the file does |
| 2 | Declarations & usages | ~100–400 | All exports, imports, variables, annotations with signatures |
| 3 | Per-symbol summaries | ~200–800 | One-sentence description per public symbol |
| 4 | Public API | ~50–200 | Layer 2 filtered to public symbols only |

**Cheap before expensive:** start with `overview` (layer 0+1 across files), then drill into `get-file` with layer 2/3 only when needed.

## Layer Selection

`get-file` accepts a `layers` parameter and defaults to `[0, 1, 4]` — enough for most decisions without pulling in every symbol description.

```
code-index: get-file
  path: "lib/src/database.dart"
  layers: [0, 1]           # just metadata + summary
```

To get full detail including per-symbol summaries:

```
code-index: get-file
  path: "lib/src/database.dart"
  layers: [0, 1, 2, 3]
```

## Handling `needs_reindex`

Every read response can include a `needs_reindex` array of files whose on-disk content has changed since they were last indexed:

```json
{
  "data": { ... },
  "needs_reindex": [
    { "path": "lib/src/foo.dart", "reason": "changed" },
    { "path": "lib/src/bar.dart", "reason": "changed" }
  ]
}
```

**Decision rule:** if correctness matters for the current question, spawn `code-index-agent` with the batch as input. Otherwise, continue with the stale data — it is usually close enough.

```
Spawn code-index-agent with:
{
  "needs_reindex": [
    { "path": "lib/src/foo.dart", "reason": "changed" },
    { "path": "lib/src/bar.dart", "reason": "changed" }
  ]
}
```

## Handling `out_of_scope`

When you query a file outside the configured `code-index` allowed paths, you get a structured response:

```json
{ "status": "out_of_scope", "allowed_paths": ["lib", "bin", "test"] }
```

This is normal. The index cannot answer about this file — read it yourself with `filesystem read-file`.

## When to Spawn `code-index-agent`

1. **Session start** — run `auto-scan` (with `rebuild: false` unless you need a full rebuild), then hand the returned plan to `code-index-agent`:

   ```
   code-index: auto-scan
   # → { plan: [...], out_of_scope: [...], allowed_paths: [...] }

   Spawn code-index-agent with the plan object
   ```

2. **On demand** — when `needs_reindex` is non-empty and freshness matters for your current question, spawn `code-index-agent` with the `needs_reindex` array.

3. **Routine reads** — do NOT spawn the agent. Just query the index directly.

## Operation Reference

All operations require the `project_dir` parameter.

### Querying

| Operation | Description | Key parameters |
|-----------|-------------|----------------|
| `overview` | Compact listing of all indexed files (layer 0+1): path, description, file type, export names. | `path_pattern`, `file_type` |
| `get-file` | Single file with selected layers. Default layers: `[0, 1, 4]`. | `path`, `layers` |
| `get-files` | Batched `get-file` for multiple files at once. | `paths`, `layers` |
| `search` | FTS5 keyword search across names, descriptions, exports, variables. Multi-word = AND. | `query`, `export_name`, `export_kind`, `file_type`, `path_pattern`, `import_pattern`, `description_pattern` |
| `usages` | Find all usages of a symbol across indexed files. | `symbol` |
| `dependents` | Find all files that import a given path. | `path` |
| `dependencies` | Get a file's imports classified as internal or external. | `path` |
| `search-annotations` | Find TODO/FIXME/HACK/NOTE/DEPRECATED across the codebase. | `kind`, `path_pattern`, `message_pattern`, `file_type` |
| `stats` | Aggregate counts: files by type, exports by kind, top imports, annotations. | — |
| `is-allowed` | Check whether a path is inside the `code-index` allowed paths. | `path` |

### Scanning (triggers indexing via agent)

| Operation | Description | Key parameters |
|-----------|-------------|----------------|
| `auto-scan` | Walk the project, diff against the index, return a plan for `code-index-agent`. Does NOT index anything itself. | `rebuild`, `since` |

### Indexing (used by `code-index-agent`, not by consumers)

| Operation | Description |
|-----------|-------------|
| `auto-index` | Write layers for a single file. Called by the agent, not by consumers. |

## Tool Reference

All tool calls MUST include the `project_dir` parameter matching one of the registered project directories. Omitting `project_dir` will return a validation error.
