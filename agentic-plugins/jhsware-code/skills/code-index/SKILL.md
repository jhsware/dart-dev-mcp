---
name: code-index
description: Query the layered code index for token-efficient codebase exploration and search.
allowed-tools: filesystem, code-index
model: haiku
context: fork
agent: code-index-agent
---

## Purpose

The code index is a persistent, layered database of file metadata. Querying it
costs ~30–400 tokens per file versus ~500–5000+ for reading source. This is the
**consumer** guide — how to *query*. Writing to the index lives in
`code-index-agent`. Every operation requires `project_dir`.

## Query patterns (start here)

**P1 — Orient** an unfamiliar area:

```
code-index: overview path_pattern="lib/auth"
→ path + summary + tags + public symbols per file, ~40 tokens each
```

**P2 — Concept search** (you know the idea, not the identifier):

```
code-index: search query="session expiry refresh"
→ semantic tags match "auth"-style vocabulary even when the code says "signIn"
→ miss? retry with synonyms, or check stats' tag cloud for the index vocabulary
```

**P3 — Jump to symbol → partial read** (the headline pattern):

```
code-index: find-symbol name="refresh" path_pattern="auth"
→ { path: "lib/src/auth/session.dart", line: 57, end_line: 74 }
filesystem: read-file path="lib/src/auth/session.dart" startLine=57 endLine=74
→ the exact 18 lines, not the 500-line file
```

**P4 — Impact analysis** (what breaks if I change this?):

```
code-index: dependents path="lib/src/auth/session.dart"     # who imports it
code-index: references symbol="SessionManager"              # who uses the symbol
code-index: references dot_path_pattern="flutter.material"  # all uses from material
code-index: references symbol="Widget" module="flutter" resolution="resolved"
                                                            # analyzer-verified only
```

**P5 — Debt sweep:**

```
code-index: annotations kind="TODO" path_pattern="auth"
```

**P6 — File facts** (line counts, sizes, freshness — no agent needed):

```
code-index: get-files paths=[...] layers=[0]
code-index: stats
```

## Cheap before expensive

Every file stores layers; pick the cheapest that answers the question.

| Layer | What it gives you | Cost |
|------:|-------------------|-----:|
| 0 | metadata: path, type, size, hash, freshness | ~30–60 |
| 1 | one-sentence summary + tags | ~20–40 |
| 2 | symbols, imports, references, annotations | ~100–400 |
| 3 | per-symbol summaries | ~200–800 |
| 4 | public API (layer 2 filtered to public) | ~50–200 |

Start with `overview`/`search`. Request layer 2/3 via `get-file` only when
needed. Read raw source last — and then only the line range from `find-symbol`.
`get-file` defaults to `layers: [0, 1, 4]`.

## Operations

| Op | Purpose | Key params |
|----|---------|-----------|
| `overview` | compact listing (layer 0+1 + public symbols) | `path_pattern`, `file_type`, `language`, `limit` |
| `search` | FTS5 across names, summaries, tags, symbols, dot-paths | `query`, `tag`, `symbol_name`, `symbol_kind`, `path_pattern`, `import_pattern`, `file_type`, `language` |
| `find-symbol` | resolve a declaration to file + line range | `name`, `match`, `kind`, `visibility`, `path_pattern` |
| `get-file` | one file's layered data | `path`, `layers` |
| `get-files` | batched `get-file` | `paths`, `layers` |
| `references` | who uses a symbol (dot-path notation) | `symbol`, `module`, `dot_path_pattern`, `resolution`, `path_pattern` |
| `dependents` | files that import a path | `path` |
| `dependencies` | a file's imports (internal/external) | `path` |
| `annotations` | TODO/FIXME/HACK/NOTE/DEPRECATED | `kind`, `message_pattern`, `path_pattern` |
| `stats` | aggregate counts + tag cloud + freshness | `limit` |
| `project-info` | does an index exist, schema, row counts | — |
| `scan` | detect changes, return an indexing `plan` | `rebuild`, `since`, `verify` |
| `is-allowed` | is a path within the allowed paths | `path` |

`scan` and `index-files` feed the writer — see the freshness policy. Consumers
never call `index-files`.

## Freshness policy

- Every read may return `needs_reindex: [{ path, reason }]`. **Rule:** if
  correctness matters for the current question, spawn `code-index-agent` with
  that batch; otherwise continue — stale summaries are usually close enough.
- **Session start:** run `scan` and, if the `plan` is non-empty, hand the
  response to `code-index-agent` before heavy querying.
- **Routine reads never spawn the agent.**
- Re-indexing a changed Dart file auto-refreshes references of its direct
  dependents — no need to re-index importers after a rename; check the agent's
  `dependents_refreshed`.

## Boundaries

- `out_of_scope` responses are normal: the index will not answer for that path —
  fall back to `filesystem read-file`.
- `project-info` tells you whether an index exists at all (fresh checkout → run
  the `scan` flow first).
