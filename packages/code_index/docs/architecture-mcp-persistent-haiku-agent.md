# Architecture: MCP as Persistent Store, Haiku Agent as Reader/Writer

**Status:** Proposal
**Date:** 2026-05-26
**Author:** sebastian@urbantalk.se

---

## 1. Motivation

The current `code-index` already keeps a SQLite index per project, hashes files with XXH3, and exposes a `diff` operation that tells callers which files have `changed`, `added`, or been `deleted` since the last index. What it does not do well today:

- Indexing is driven entirely from outside (the parent agent or the skill must orchestrate `diff` → `read` → `auto-index` itself). This wastes parent context.
- Only one layer of information is stored per file (description + structural metadata). A consumer that only needs a one-line summary still pays for the full payload, and a consumer that needs deeper per-function summaries cannot get them at all.
- A query against a file that has changed on disk silently returns stale data — the consumer has no way to know it needs to re-index unless they call `diff` first.
- The Haiku-backed agent exists, but the parent has to spawn it and re-spawn it. There is no clean "query the index, and if a file is stale or missing, the index transparently re-analyzes it" path.

The proposal is to make the **MCP the source of truth and the controller**, and the **`code-index-agent` (Haiku) the worker** the MCP delegates to whenever it needs to *write* new analysis. The parent agent never has to know about Haiku, never has to orchestrate scans, and never reads raw files just to populate the index.

---

## 2. Architectural Principles

1. **MCP is the durable layer.** All persistent state lives in the per-project SQLite database. Nothing important lives in the agent's context window.
2. **The agent is stateless and disposable.** Each invocation of `code-index-agent` starts with a fresh context. The MCP tells it exactly which files to look at and which layers to produce.
3. **Layered storage, layered retrieval.** Every file has multiple precomputed views. Consumers ask for the cheapest layer that answers their question.
4. **Stale-on-read is automatic.** The MCP compares hashes during query operations, not just `diff`. If the file on disk has changed, the MCP either returns the stale data with a `stale: true` flag or transparently dispatches the agent to refresh it (configurable per call).
5. **Out-of-bounds is loud.** Any operation that touches a path outside the `jhsware-code.yaml` allowed paths returns a structured `out_of_scope` response, never silently fails. The consumer can then run its own analysis on that file.
6. **Backward compatibility.** Existing operations (`index-file`, `auto-index`, `search`, `show-file`, `diff`, `overview`, `file-summary`, `dependents`, `dependencies`, `search-annotations`, `stats`) keep working. New layers are additive.

---

## 3. Allowed Paths via `jhsware-code.yaml`

The plumbing already exists. `ProjectConfigService.getAllowedPaths(projectDir, 'code-index')` is called in `bin/code_index_mcp.dart` and passed into `IndexOperations` and `DiffOperations`. Today only `DiffOperations` enforces it via `isAllowedPath`.

The proposal extends enforcement uniformly:

```yaml
# jhsware-code.yaml (example)
allowed-paths:
  filesystem:
    - lib
    - test
    - docs
    - pubspec.yaml
  git:
    - .
  code-index:
    - lib
    - test
    - bin
    - pubspec.yaml
```

### Rules

- Every operation that takes a `path` (or implicitly walks the tree, like `diff` or `auto-scan`) MUST resolve that path against the `code-index` allowed list.
- If a single path is out of scope, the operation returns:
  ```json
  {
    "status": "out_of_scope",
    "path": "scripts/build.sh",
    "allowed_paths": ["lib", "test", "bin", "pubspec.yaml"],
    "message": "Path 'scripts/build.sh' is outside code-index allowed paths. The caller should analyze this file directly."
  }
  ```
- If a batch (e.g. `auto-scan`) encounters mixed in-scope and out-of-scope paths, the in-scope work proceeds and the response includes an `out_of_scope` array so the consumer knows what was skipped.
- If `jhsware-code.yaml` is missing, the existing fallback (full project root access) remains, matching how `filesystem` and `git` behave.

A small `is-allowed` operation should also be exposed so a consumer can ask "is this file even something you can answer about?" before calling anything that mutates.

---

## 4. Layered Information Model

Every indexed file holds five layers. A consumer picks the cheapest layer that answers their question.

| Layer | Name | Cost to produce | Token size (typical) | When to use |
|------:|------|-----------------|-----------------------|-------------|
| 0 | **Metadata** | Free (filesystem stat + parse) | ~30–60 tokens | Listing files, filtering by type/size, deciding whether to look deeper |
| 1 | **Short summary** | 1 cheap Haiku call | ~20–40 tokens | "What does this file do?" across many files |
| 2 | **Symbol list / signatures** | Deterministic parser (Dart) or Haiku (other langs) | ~100–400 tokens | "What's defined here?", search by symbol |
| 3 | **Per-symbol summaries** | 1 Haiku call per file (longer) | ~200–800 tokens | "What does each function do?" without reading source |
| 4 | **Exposed public API** | Derived from layer 2 (filtered) | ~50–200 tokens | "What's the contract this file offers to callers?" |

Layer 5 is the raw file content itself — not stored in the index, but `filesystem read-file` is always the escape hatch.

### Layer 0 — Metadata

Cheap, deterministic, always populated, always fresh.

```json
{
  "path": "lib/src/database.dart",
  "name": "database.dart",
  "file_type": "dart",
  "size_bytes": 9456,
  "line_count": 287,
  "file_hash": "a3f9c1...",
  "mtime": "2026-05-20T10:14:33Z",
  "indexed_at": "2026-05-20T10:15:01Z",
  "layers_present": [0, 1, 2, 3, 4],
  "stale": false
}
```

`stale` is computed on read by comparing the on-disk hash with the stored hash.

### Layer 1 — Short summary

One sentence. Always present alongside layer 0 once a file has been indexed.

```json
{ "summary": "Initializes the code-index SQLite database, runs schema migrations, and manages shutdown." }
```

### Layer 2 — Symbol list / signatures

The existing `exports`, `variables`, `imports`, `annotations` rows. For Dart, produced by the existing deterministic parser (`dart_parser.dart`). For other languages, produced by Haiku.

### Layer 3 — Per-symbol summaries

A short paragraph attached to each export. Stored on the `exports.description` column (which already exists). Haiku produces these in the same pass as layer 1.

### Layer 4 — Exposed public API

A *view* over layer 2 filtered to public symbols (e.g. exclude private prefixes like `_` in Dart). No new storage needed — just a query/operation.

### Layer selection at query time

```
code-index: get-file
  path: "lib/src/database.dart"
  layers: [0, 1]            # request only metadata + short summary
```

If `layers` is omitted, the operation defaults to `[0, 1, 4]` — enough to make most decisions without dragging in every function description.

---

## 5. Database Schema Additions

> **Implementation note (2026-05-26):** The `currentSchemaVersion` migration plan described below was replaced by **clean-rebuild semantics**. The database stores a `schema_version` stamp; if the on-disk version differs from the code's expected version, the entire database file is deleted and recreated with the current schema. This eliminates migration complexity at the cost of a one-time re-index when the schema changes.

Bump `currentSchemaVersion` from 4 to 5 and add via migration:

```sql
ALTER TABLE files ADD COLUMN size_bytes INTEGER;
ALTER TABLE files ADD COLUMN line_count INTEGER;
ALTER TABLE files ADD COLUMN mtime TEXT;
ALTER TABLE files ADD COLUMN short_summary TEXT;        -- layer 1
ALTER TABLE files ADD COLUMN layers_present TEXT;       -- JSON array, e.g. "[0,1,2,3,4]"
ALTER TABLE files ADD COLUMN last_analyzed_at TEXT;     -- when Haiku last touched it
ALTER TABLE files ADD COLUMN analysis_status TEXT;      -- 'fresh' | 'stale' | 'pending' | 'failed'
ALTER TABLE files ADD COLUMN analysis_error TEXT;       -- last error message if failed
```

Layer 3 already maps onto the existing `exports.description` column. No new table required.

A small `scan_queue` table for the background-worker pattern (optional, see §7):

```sql
CREATE TABLE scan_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL,
  reason TEXT NOT NULL,        -- 'added' | 'changed' | 'on_demand'
  layers_requested TEXT,       -- JSON array
  enqueued_at TEXT NOT NULL,
  picked_up_at TEXT,
  completed_at TEXT,
  status TEXT NOT NULL         -- 'queued' | 'in_progress' | 'done' | 'failed'
);
```

---

## 5a. Per-File Data Specification

This section concretizes what is stored per file in the index, building on §4 (layers) and §5 (storage). All fields below are exposed through the read API; the `Kind` column indicates how the value is produced.

### 5a.1 Field-by-field specification

| Field | Layer | Kind | Description |
|-------|:-----:|------|-------------|
| `path` | 0 | deterministic | Relative path from project root. |
| `name` | 0 | deterministic | File basename. |
| `file_type` | 0 | deterministic | Extension-derived (e.g. `dart`, `yaml`). |
| `size_bytes` | 0 | deterministic | `stat`-derived. |
| `line_count` | 0 | deterministic | Total newlines + 1. |
| `word_count` | 0 | deterministic | Whitespace-delimited token count. Useful for "how big is this really" estimates. |
| `file_hash` | 0 | deterministic | XXH3-64 of file bytes (already implemented). |
| `mtime` | 0 | deterministic | Filesystem modification time. |
| `short_summary` | 1 | Haiku | One sentence: what the file provides. |
| `imports` | 2 | analyzer / regex | Import path strings (already stored in `imports` table). |
| `symbols` | 2 | analyzer / regex | All declarations defined *in this file*: classes, functions, variables, enums, methods, mixins, extensions, typedefs. Maps to the existing `exports` + `variables` tables. |
| `external_usages` | 2 | analyzer (resolved) | All symbols this file *uses* from outside, in dot notation (see §5a.3). Searchable. New table. |
| `annotations` | 2 | regex | TODO/FIXME/HACK/NOTE/DEPRECATED (already stored). |
| `symbol_summaries` | 3 | Haiku | Per-symbol description on each row of `exports`/`variables`. |

### 5a.2 In-file symbols vs exports

Today the schema labels this table `exports`. Many of the symbols stored aren't actually exported (top-level functions, class members, private getters), so the name is misleading. For clarity, the **API** should call this set `symbols` (or `declarations`) while the **table** name `exports` stays for backward compatibility. A filter parameter `visibility: "public" | "all"` (default `"public"`) determines whether private members (Dart `_`-prefixed, etc.) are returned.

### 5a.3 External symbol usages — dot notation

The goal: enable queries like *"which files in my project use `Widget` from Flutter material?"* without re-parsing source on demand.

Each external reference is stored as a row mapping `(file_id → dot_path)`. The dot-path canonicalizes the source location and the symbol name into a single token-friendly string.

#### Format

```
<module>.<source_path>.<symbol>
```

- `<module>` — the package name. For `package:foo/...` → `foo`; for `dart:core` → `dart`; for relative imports inside this project → the project's package name from `pubspec.yaml`.
- `<source_path>` — the path of the source file *inside* that package, with directory separators replaced by dots and the file extension removed. `package:flutter/src/widgets/framework.dart` becomes `src.widgets.framework`. For `dart:io`, this is just `io`.
- `<symbol>` — the canonical name as imported.

Examples:

| Source | Dot path |
|--------|----------|
| `Widget` from `package:flutter/material.dart` | `flutter.material.Widget` |
| `File` from `dart:io` | `dart.io.File` |
| `compute` from `package:flutter/foundation.dart` | `flutter.foundation.compute` |
| `MyService` from `lib/services/my_service.dart` (this project, package `myapp`) | `myapp.lib.services.my_service.MyService` |

Dots are ideal for FTS5: the default tokenizer splits on non-alphanumeric, so a search for `Widget` matches everything containing `Widget` regardless of source module, while a search for `material` matches all imports from material. Filters can also operate on the prefix columns (`module`, `source_path`) directly.

#### Storage

```sql
CREATE TABLE external_symbol_usages (
  id TEXT PRIMARY KEY,
  file_id TEXT NOT NULL,
  module TEXT NOT NULL,
  source_path TEXT NOT NULL,       -- already dotted (no slashes, no extension)
  symbol TEXT NOT NULL,
  symbol_kind TEXT,                -- class, function, method, variable, enum, typedef, mixin, extension, unknown
  dot_path TEXT NOT NULL,          -- pre-joined module.source_path.symbol
  reference_count INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
  UNIQUE(file_id, dot_path)
);

CREATE INDEX idx_ext_usages_symbol   ON external_symbol_usages(symbol);
CREATE INDEX idx_ext_usages_module   ON external_symbol_usages(module);
CREATE INDEX idx_ext_usages_dot_path ON external_symbol_usages(dot_path);
```

A new column on `code_search_fts` named `external_symbols` holds `GROUP_CONCAT(dot_path, ' ')` per file so FTS queries reach these tokens.

#### New / modified operations

- `code-index: usages` — Search the external-usage index. Parameters: `symbol`, `module`, `source_path`, `dot_path_pattern`, `kind`, `path_pattern`. Returns the list of files where each match occurs, with `reference_count` per file.
- `code-index: get-file` — When `layers` includes `2`, the response includes `external_usages` alongside `imports` and `symbols`.
- `code-index: search` — Queries also match against `external_symbols` via the FTS column above.

### 5a.4 Schema delta added on top of §5

In addition to the migration listed in §5, the v5 migration adds:

```sql
ALTER TABLE files ADD COLUMN word_count INTEGER;
-- plus the external_symbol_usages table from §5a.3 and the
-- external_symbols column on code_search_fts.
```

---

## 5b. Extraction Strategy: What Dart Tooling Can Provide

Different fields have different cheapest-reliable producers. The architecture picks per field rather than committing to one tool for everything.

### 5b.1 The four producers

**Regex / brace-counting (current `dart_parser.dart`).** Already extracts imports, top-level declarations, class members, and annotations. It cannot resolve names — it doesn't know that `Widget` in `class Foo extends Widget` came from `package:flutter/material.dart`, because that requires looking at the imports and their actual contents. Fine for declarations, insufficient for external-usage tracking.

**`package:analyzer` (the Dart analyzer).** A pure-Dart library — drop-in dependency. It's the same analyzer that powers `dart analyze`, the IntelliJ/VS Code Dart plugin, and the Dart language server. Two modes:

- *Syntactic* (`parseFile`) — fast (~ms per file), produces an unresolved AST. Same information as the regex parser, but structured and robust against edge cases (extension types, patterns, sealed classes, etc.). Replaces `dart_parser.dart` cleanly.
- *Resolved* (`AnalysisContextCollection` → `getResolvedUnit`) — slower (a one-time context build of a few seconds per project, then tens of ms per file). Returns a fully resolved AST: every identifier has an `Element`, every `Element` knows its `LibraryElement`, every library knows its `source.uri` (e.g. `package:flutter/material.dart`).

Resolved mode is what makes the dot-path notation possible. The pattern is:

```dart
final element = node.staticElement;             // Element
final library = element?.library;               // LibraryElement
final uri     = library?.source.uri.toString(); // "package:flutter/material.dart"
final symbol  = element?.displayName;           // "Widget"
final kind    = element?.kind.name;             // "CLASS", "FUNCTION", etc.
```

Parsing `uri` into `(module, source_path)` and combining with `symbol` deterministically produces the dot-path.

**Dart language server (LSP).** Implemented on top of the same analyzer. For batch indexing, the analyzer is the right level of abstraction — going through LSP adds JSON-RPC overhead, request lifecycle, and a long-lived process to manage. LSP is the right choice for an editor; the analyzer is the right choice for an indexer. **Recommendation: use `package:analyzer` directly.**

**Haiku.** Used only where deterministic tools can't reach: layer 1 (short summary) and layer 3 (per-symbol summaries). For non-Dart files, Haiku additionally produces the structural metadata that the analyzer produces for free on Dart files.

### 5b.2 Field-to-producer mapping

| Field | Dart files | Non-Dart files |
|-------|------------|----------------|
| `size_bytes`, `line_count`, `word_count`, `file_hash`, `mtime` | `dart:io` + xxh3 (already) | Same |
| `imports` | analyzer (syntactic); current regex parser also works | Haiku |
| `symbols` (in-file declarations) | analyzer (syntactic) | Haiku |
| `external_usages` (dot paths) | **analyzer (resolved)** — no other reliable option | Haiku (best-effort; this is the weakest field for non-Dart) |
| `annotations` | regex (already) | regex |
| `short_summary` | Haiku | Haiku |
| `symbol_summaries` | Haiku | Haiku |

### 5b.3 Migration of the existing parser

The current `dart_parser.dart` is competent for what it does, but `external_usages` cannot be added on top of it without writing a resolver from scratch. Two options:

1. **Keep `dart_parser.dart` for declarations + add an analyzer-based resolver for external usages only.** Lowest risk, two code paths.
2. **Replace `dart_parser.dart` with an analyzer-based parser handling both declarations and external usages.** Single source of truth, but requires re-validating output against the existing `test/dart_parser_test.dart` suite.

The recommendation is **option 2**, sequenced after the rest of the v5 schema work has stabilized. The analyzer's syntactic mode is already at parity with the current regex parser on the fields we care about (and more accurate on edge cases like extension types and recent Dart pattern syntax).

### 5b.4 Cost model

Per file during a full rescan:

- **Layer 0** — negligible (a stat + hash).
- **Layer 2** (declarations + external usages) — analyzer-resolved is the dominant CPU cost: a few tens of milliseconds per file once the analysis context is warm, plus a one-time context build of a few seconds at the start of a scan.
- **Layers 1 + 3** (Haiku) — one Haiku call per file. Dominant *token* cost.

For a 500-file Dart project, that is roughly: a few seconds of analyzer setup, a few more seconds of resolved analysis, and ~500 Haiku calls. The analyzer cost is paid once at startup; the Haiku cost is incremental and only re-incurred for files whose hash changed since the last index.

### 5b.5 Dependency change

Adding `analyzer` to `packages/code_index/pubspec.yaml`:

```yaml
dependencies:
  analyzer: ^6.5.0   # or whichever version aligns with the SDK in use
```

This is the same dependency that the Dart SDK and Flutter tooling already pull in transitively, so it's a well-trodden choice. No new build steps, no native dependencies, no separate process.

---

## 6. New / Modified MCP Operations

### New

- **`auto-scan`** — Walks the project (respecting `code-index` allowed paths), runs `diff` internally, and returns a *plan* describing which files need which layers. Does NOT call Haiku itself; emits a structured plan that the agent (or another caller) can execute.

  ```json
  {
    "added": ["lib/foo.dart"],
    "changed": ["lib/bar.dart"],
    "deleted": ["lib/baz.dart"],
    "out_of_scope": ["scripts/build.sh"],
    "plan": [
      { "path": "lib/foo.dart", "needs": [0, 1, 2, 3] },
      { "path": "lib/bar.dart", "needs": [0, 1, 3] }
    ],
    "summary": { "files_to_analyze": 2, "estimated_haiku_calls": 2 }
  }
  ```

- **`get-file`** — Replaces ad-hoc combinations of `show-file` / `file-summary`. Takes `path` and `layers`, returns only what was asked for, plus the `stale` flag.

- **`get-files`** — Batched version of `get-file` for cross-file queries.

- **`is-allowed`** — Returns whether a path is inside the `code-index` allowed paths.

- **`mark-stale`** — Force-mark a file as stale (used by external file watchers if a project ever wires one up).

### Modified

- **`auto-index`** — Continues to be the write path. Extended to accept `layers` (which layers to compute) and to populate `short_summary`, `size_bytes`, `line_count`, `mtime`, `layers_present`, `analysis_status`, `last_analyzed_at`. Still callable directly by an agent batch.

- **`show-file` / `file-summary`** — Keep them for backward compatibility, but internally route through `get-file` with a fixed layer set.

- **Every read operation** (`get-file`, `show-file`, `file-summary`, `search`, `overview`, `dependents`, `dependencies`) — When returning data for a file, recompute the hash (cheap with XXH3) and compare with the stored hash. If they differ, set `stale: true` on the response and update `analysis_status` to `stale` in the database. Behavior on stale is controlled by a per-call parameter:
  - `on_stale: "return_stale"` (default) — return the stored data with `stale: true`.
  - `on_stale: "refresh"` — enqueue the file in `scan_queue`, return stored data with `stale: true, refresh_enqueued: true`.
  - `on_stale: "refresh_and_wait"` — synchronously trigger the agent to re-analyze the file before returning. Only sensible for one-shot consumers that don't mind waiting (this requires the agent integration described in §7).

- **`diff`** — Already does what we want. Used internally by `auto-scan`. Still callable directly.

### Operation matrix

| Op | Reads | Writes | Walks tree | Calls Haiku | Allowed-path check |
|----|:---:|:---:|:---:|:---:|:---:|
| `auto-scan` | ✓ | — | ✓ | — | ✓ |
| `diff` | ✓ | — (except `remove_deleted`) | ✓ | — | ✓ |
| `get-file` / `get-files` | ✓ | hash-refresh only | — | — (unless `refresh_and_wait`) | ✓ |
| `show-file` / `file-summary` / `overview` | ✓ | hash-refresh only | — | — | ✓ |
| `search` / `search-annotations` / `stats` | ✓ | — | — | — | — (querying index only) |
| `auto-index` / `index-file` | — | ✓ | — | — | ✓ |
| `is-allowed` | — | — | — | — | ✓ |

---

## 7. Progressive Scan: How and When

Three triggers fire a scan.

### 7.1 Startup scan

When the MCP process boots, it does *not* block on indexing. Instead, on the first operation against a given project (or on a separate `auto-scan` call), it runs `diff` and stages the results in `scan_queue`. This keeps the MCP responsive.

Two execution models for processing the queue:

**Model A — Pull-based (recommended starting point).**
The MCP exposes the queue. The agent (or the skill) calls `auto-scan` to get the plan, then issues `auto-index` calls in batches. The MCP does not own a worker thread. This is the simplest evolution from where we are today and keeps the MCP single-threaded against SQLite.

**Model B — Push-based (later, if needed).**
The MCP forks the `code-index-agent` itself via an internal process spawn or by emitting an MCP notification that the host runtime acts on. This is more invasive (the MCP needs to be able to talk to a Claude API or to the host SDK) and is deferred.

For the initial implementation, choose Model A: the parent invokes the agent once at the start of a session ("bring the index up to date"), and Haiku does the heavy work in a forked context.

### 7.2 On-read stale detection

Every operation that returns file-scoped data does a hash check (XXH3 is fast — sub-millisecond for typical source files). Three things can happen:

1. **Hash matches** → return data, `stale: false`.
2. **Hash differs**, `on_stale: "return_stale"` → return stored data, `stale: true`, mark `analysis_status='stale'` in the DB.
3. **Hash differs**, `on_stale: "refresh"` → as above, plus enqueue the file. Next time the agent runs, it will pick it up.
4. **Hash differs**, `on_stale: "refresh_and_wait"` → MCP signals the host to spawn the agent for this single file, blocks until it completes (with a timeout), then returns fresh data.

Most callers should leave the default (`return_stale`). A parent agent that *cares* about freshness for a particular question can opt in to `refresh` or `refresh_and_wait`.

### 7.3 Explicit refresh

Callers can always issue `auto-scan` followed by an `code-index-agent` invocation to bring the index fully up to date. This is the workflow the existing skill already encourages.

---

## 8. The Haiku Agent — Updated Role

`agents/code-index-agent.md` already declares `model: haiku`, `tools: filesystem, code-index`, `skills: [code-index]`. Three behavioral updates:

### 8.1 New mode: "Process the scan plan"

When invoked with a plan from `auto-scan`, the agent:

1. Reads each file via `filesystem read-files` in batches of 5–10.
2. For Dart files, calls `code-index auto-index` with the layers it was asked to produce. Layer 0 + 2 are derived deterministically by the MCP itself; layer 1 (short summary) and layer 3 (per-symbol summaries) are what Haiku is actually producing.
3. For non-Dart files, additionally extracts the structural metadata that the Dart parser would produce automatically.
4. Reports back which files succeeded, failed, or were out-of-scope.

### 8.2 Layer-aware indexing

`auto-index` accepts a `layers` parameter so the agent doesn't waste tokens producing layer 3 when the consumer only needs layers 0–1. The skill describes which layers map to which questions and tells the agent how to prioritize.

### 8.3 Out-of-scope handoff

If the agent is asked to index a file that the MCP reports as `out_of_scope`, the agent should not attempt to work around it. It returns the path and reason to the caller, who can decide whether to read the file themselves with `filesystem`.

---

## 9. The Skill — Updated Role

`skills/code-index/SKILL.md` becomes a layered-query guide aimed at parent agents (not at the indexing process itself, which now lives in the agent).

It teaches the parent:

- How to ask cheap questions first (layer 0/1) before drilling into layer 3.
- That `get-file` takes a `layers` parameter and that the default is `[0, 1, 4]`.
- That `stale: true` in a response means "the index is behind disk — decide whether to refresh".
- That `out_of_scope` responses are normal and indicate the consumer should fall back to `filesystem`.
- When to spawn `code-index-agent` (only when the parent wants a refresh; routine reads never spawn the agent).

It stops being the indexing playbook; that playbook moves into the agent file. The skill becomes the **consumer-side** guide.

---

## 10. End-to-End Flows

### 10.1 First-time use in a session

```
parent → code-index: auto-scan
         ← { plan: [...20 files...], out_of_scope: [...] }

parent → Spawn code-index-agent with the plan
         (agent uses Haiku, writes layer 1 + layer 3 via auto-index)
         ← { indexed: 20, failed: 0 }

parent → code-index: search query="auth"
         ← matches (all fresh)
```

### 10.2 Read against a file that changed on disk

```
parent → code-index: get-file path="lib/foo.dart" layers=[0,1,4]
         (MCP hashes lib/foo.dart, detects change)
         ← { ...stored layers..., stale: true }

parent → (decides it matters) → code-index: get-file
                                  path="lib/foo.dart"
                                  layers=[0,1,4]
                                  on_stale="refresh_and_wait"
         (MCP triggers agent, agent re-indexes file)
         ← { ...fresh layers..., stale: false }
```

### 10.3 Read against an out-of-scope file

```
parent → code-index: get-file path="scripts/build.sh"
         ← { status: "out_of_scope", allowed_paths: [...] }

parent → filesystem: read-file path="scripts/build.sh"
         (parent analyzes it itself)
```

### 10.4 Multiple queries during one conversation (the headline goal)

```
parent → code-index: overview path_pattern="lib/auth/%"  (layer 0+1 across files)
         ← compact listing

parent → code-index: get-file path="lib/auth/login.dart" layers=[2,3]
         ← signatures + per-function summaries

parent → code-index: dependents path="lib/auth/login.dart"
         ← list of importers

parent → ...more queries, never re-indexing, never re-reading files...
```

Each query is a cheap MCP call against SQLite. Nothing forks Haiku unless something is stale and the parent asked for a refresh.

---

## 11. Pros and Cons Recap

**Pros**
- Persistent across sessions — opening Cowork tomorrow finds yesterday's index intact.
- Parent context stays clean — the parent never reads raw source just to populate context.
- Layered storage lets consumers pay for only what they need.
- Stale detection is automatic; the consumer can't accidentally use outdated index data without being told.
- Out-of-scope is structured, not a silent failure — callers always know when they have to take over.
- Existing Dart parser, hashing, FTS5, and allowed-paths plumbing all stay; the work is mostly additive.

**Cons**
- Hash-on-read adds a small I/O cost to every `get-file`. (XXH3 of source-sized files is sub-millisecond, so this is negligible in practice.)
- Layer 3 (per-symbol summaries) is the most expensive layer to produce; large codebases need a one-time bulk index that costs real Haiku tokens. Mitigated by making layer 3 opt-in via the `layers` parameter.
- `refresh_and_wait` requires the MCP to be able to spawn the agent, which is the part of the design that currently has no implementation — Model A keeps the parent in control of agent spawning until we decide to invest in Model B.
- Two writers (the agent and any manual `index-file` callers) means the schema needs `analysis_status` to be honest about whether a row reflects current disk state; transactional updates around hash + layers prevent inconsistency.

---

## 12. Implementation Order

A pragmatic sequence that keeps the system working at every step:

1. **Schema migration to v5** — add the new columns and `scan_queue` table. No behavior change yet.
2. **Allowed-path enforcement across all operations** — extend the `isAllowedPath` check from `DiffOperations` to all read/write ops. Introduce the `out_of_scope` response shape.
3. **`is-allowed` operation** — small, lets callers ask cheaply.
4. **Hash-on-read** — compute and compare hashes inside `show-file` / `file-summary` / `overview` / new `get-file`. Add the `stale` flag to responses.
5. **`get-file` / `get-files` with `layers` parameter** — new read API; existing ops keep working.
6. **`short_summary` storage and population** — extend `auto-index` to accept and store layer 1; update the agent to produce it.
7. **`auto-scan` operation** — emits the plan structure. The agent's "Process the scan plan" mode consumes it.
8. **Skill rewrite** — repoint from "how to index" to "how to query the layered index".
9. **Agent rewrite** — emphasize plan-driven batches and layer-aware indexing.
10. **(Later, optional) Model B push-based scanning** — MCP-initiated agent spawning for `refresh_and_wait`.

Steps 1–4 give us correctness (no more silent stale reads, no more silent out-of-scope failures) without any new layer infrastructure. Steps 5–9 unlock the layered, multi-query workflow the parent actually wants.

---

## 13. Open Questions

> All questions below were resolved during the code-index rewrite (2026-05-26).

- Should layer 3 (per-symbol summaries) be stored on `exports.description` (already there) or on a separate `export_summaries` table to allow versioning of summary style? Starting with the existing column keeps the change small.
  > **Resolved: `exports.description` is the storage for layer 3.** The existing column is used directly. No separate table was added — keeping the change small and avoiding schema complexity.

- How should the MCP know when the host runtime has spawned `code-index-agent` so it can clear the `scan_queue` rows? For Model A this is moot (the agent writes through `auto-index`, which clears its own queue entry as a side effect); for Model B it needs explicit signaling.
  > **Resolved: Model A (pull-based) was chosen.** The parent agent calls `auto-scan` to get the plan, then issues `auto-index` calls in batches. The MCP does not own a worker thread. The `scan_queue` table was not implemented — the plan-based flow makes it unnecessary.

- Should `auto-scan` accept a `since` timestamp so we can avoid hashing files that haven't been touched at all (using `mtime` as a fast pre-filter before hashing)? Probably yes — cheap optimization.
  > **Resolved: Yes.** `auto-scan` accepts a `since` parameter (ISO 8601 timestamp). Files with mtime older than the threshold are skipped without hashing.

- Do we want a `code-index: invalidate path=...` for the case where the consumer knows it just edited a file and wants the index to reflect that immediately, without waiting for the next read? Probably yes — small operation.
  > **Resolved: No dedicated `invalidate` operation.** Instead, `get-file` / `get-files` return a `needs_reindex` array listing stale files detected via hash comparison. The caller batches these into `auto-index` calls. This avoids a separate invalidation path and keeps the flow unified.

---

## 14. Summary

The architecture keeps the MCP as the durable, query-answering core; turns the Haiku agent into a worker that the MCP delegates writes to via a structured plan; introduces a layered information model so consumers can pick how much detail they pay for; makes staleness explicit on every read; and extends `jhsware-code.yaml` allowed-path checking to every operation so out-of-scope is a first-class, recoverable response. The existing hash + diff + Dart parser foundations carry directly into the new design — most of the work is schema additions, response-shape additions, and a rewrite of the skill/agent contracts to match.
