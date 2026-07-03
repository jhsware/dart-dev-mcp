# Code Index v2 — Architecture & Design

**Status:** Approved design — implementation not started
**Date:** 2026-07-03
**Revised:** 2026-07-03 — restored analyzer-resolved dot-paths for Dart and added the reference lifecycle (§8.4–§8.5)
**Author:** sebastian@urbantalk.se
**Supersedes:** `architecture-mcp-persistent-haiku-agent.md` (v1 as-built, 2026-05-26)
**Related:** `vector-search-research.md` (2026-02-14), `design-v2-agent-and-skill.md` (contracts for the Haiku agent and the consumer skill)

---

## 1. Purpose

`code_index` is an MCP server that maintains a persistent, layered SQLite index of the files in a project so that agents can explore and search a codebase without reading raw source into their context window. A Haiku-backed worker agent (`code-index-agent`) reads files via the `filesystem` tool and writes summaries and structure into the index; consumer agents query the index through cheap, targeted operations.

v2 is a full rewrite. It keeps the ideas that proved out in v1 (layered storage, hash-based change detection, stale-on-read, plan-driven indexing, FTS5 search, resolved dot-path references, allowed-paths scoping) and changes four fundamentals:

| # | Decision (design review 2026-07-03) | v1 | v2 |
|---|--------------------------------------|----|----|
| 1 | **Storage location** | `[planner-data-root]/projects/[name]/db/code_index.db` — coupled to planner infrastructure | `~/.code-index/<basename>-<hash8>/code_index.db` — standalone, plus a central `registry.json` |
| 2 | **Change detection hash** | XXH3-64 | **SHA-256** with an mtime+size short-circuit |
| 3 | **Structural extraction** | `package:analyzer` for Dart, agent for other languages; per-call analysis context | **Hybrid, accuracy-preserving:** `package:analyzer` behind a **warm per-project context** produces Dart layer 2 — symbols with exact line ranges and **resolved dot-path references**. The Haiku agent produces layer 2 for all other languages and layers 1/3 everywhere. `xxh3` is dropped; `analyzer` stays. |
| 4 | **Semantic search** | FTS5 keywords only | FTS5 **plus Haiku-generated semantic tags** per file (the lightweight path recommended in `vector-search-research.md`) |

> **Revision note (2026-07-03):** the first draft of this design chose agent-only extraction (a fully language-agnostic MCP). It was revised the same day to keep v1's analyzer-resolved dot-paths: the accuracy of the reference graph — "which files use `Widget` *from flutter.material*" — is worth the dependency. What changes vs v1 is *how* the analyzer is used: one warm context per project instead of a rebuilt context per call, and a defined reference lifecycle on re-index (§8.5).

Further v2 additions that fall out of the rewrite:

- **Symbols carry line ranges** (`line`, `end_line`) — analyzer-exact for Dart, derived from line-numbered `read-file` output by the agent for other languages. This enables the headline token-saving pattern: `find-symbol` → `filesystem read-file startLine/endLine` — read 20 lines instead of 500.
- **Batched writes** (`index-files`) replace the per-file `auto-index` call, cutting MCP round trips during indexing.
- **Automatic dependent refresh:** re-indexing a changed Dart file also re-resolves the references of the files that depend on it — analyzer-only, no LLM involved (§8.5).

---

## 2. Architectural Principles

1. **MCP is the durable layer.** All persistent state lives in per-project SQLite databases under `~/.code-index`. Nothing important lives in any agent's context window.
2. **Language-agnostic interface, pluggable extraction.** The MCP computes deterministic filesystem facts (layer 0) for every file, and deterministic structure (layer 2) for languages it has an extractor for — currently Dart via `package:analyzer` (syntactic declarations + resolved external references + regex annotations). For every other language, structure arrives from the indexing agent through the same `index-files` record shape and is normalized into the same tables. The MCP never calls an LLM.
3. **The agent is stateless and disposable.** Each `code-index-agent` invocation starts fresh, receives an explicit plan, and reports what it did.
4. **Layered storage, layered retrieval.** Consumers request the cheapest layer that answers their question.
5. **Stale-on-read is automatic.** Read operations compare disk state against the stored hash and surface `needs_reindex` batches. Stored data is still returned — the caller decides whether freshness matters.
6. **Out-of-scope is loud.** Paths outside the `jhsware-code.yaml` allowed list return structured `out_of_scope` responses, never silent failures.
7. **Clean break.** No migrations, no legacy operation wrappers. Schema mismatch triggers a full database rebuild (v1's clean-rebuild strategy, kept).

---

## 3. Storage Layout

### 3.1 Directory structure

```
~/.code-index/
├── registry.json                          # central project registry
├── jhsware_code-3fa2b1c9/                 # <sanitized-basename>-<hash8>
│   ├── code_index.db                      # SQLite database (WAL mode)
│   ├── code_index.db-wal / -shm           # SQLite sidecars
│   └── meta.json                          # per-project metadata
└── planner_server-9c01d44e/
    ├── code_index.db
    └── meta.json
```

- `<sanitized-basename>` — project directory basename with any character outside `[A-Za-z0-9._-]` replaced by `_`.
- `<hash8>` — first 8 hex characters of `sha256(canonicalProjectPath)`, where the canonical path is the absolute project path with symlinks resolved (`Directory.resolveSymbolicLinksSync()`). This makes directory names human-readable **and** collision-proof: two projects both named `app` get distinct directories.
- The data root defaults to `~/.code-index` and can be overridden with `--data-root=PATH` (used by tests; also useful for CI).

### 3.2 registry.json

Central lookup so tooling (and humans) can map project paths to data directories without re-deriving hashes, and so renames are discoverable.

```json
{
  "version": 1,
  "projects": {
    "/Users/jhsware/DEV/agentic-coding/jhsware_code": {
      "dir": "jhsware_code-3fa2b1c9",
      "name": "jhsware_code",
      "created_at": "2026-07-03T09:00:00Z",
      "last_opened_at": "2026-07-03T09:00:00Z"
    }
  }
}
```

Rules:

- Updated when a project database is first created and on first open per server process (`last_opened_at`).
- Written atomically: serialize to `registry.json.tmp`, then rename over the original.
- The registry is advisory — the source of truth for "which directory belongs to this project" is the deterministic `<basename>-<hash8>` derivation. If the registry is deleted, it is rebuilt lazily as projects are opened.

### 3.3 meta.json (per project directory)

Self-describing marker so a data directory can be understood without the registry:

```json
{
  "project_path": "/Users/jhsware/DEV/agentic-coding/jhsware_code",
  "project_name": "jhsware_code",
  "schema_version": 2,
  "created_at": "2026-07-03T09:00:00Z"
}
```

On open, if `meta.json` exists and `project_path` does not match the requesting project, the server refuses with a clear error (guards against the astronomically unlikely hash-prefix collision and against manual directory shuffling).

### 3.4 Schema versioning — clean rebuild

Kept from v1. The schema version is stored in `PRAGMA user_version` (mirrored in `meta.json` for human inspection). On open, if `user_version` differs from the expected version, the database file and its WAL/SHM sidecars are deleted and recreated with the current schema. The next `scan` reports every file as `added`, triggering a full re-index. No migration machinery exists. The version is also bumped when the Dart extractor's output changes materially (e.g. a major `analyzer` upgrade changes resolution results), forcing a consistent rebuild rather than a mixed-precision index.

---

## 4. Change Detection

### 4.1 SHA-256 content hashing

Every indexed file stores the SHA-256 hex digest of its content bytes (`package:crypto`, streamed). SHA-256 replaces v1's XXH3-64: it is a few times slower but still sub-millisecond for typical source files, is available as a pure-Dart dependency already used across the ecosystem, and its digests are stable, standard, and reusable (e.g. comparable with `git hash-object`-style tooling or external systems if ever needed).

### 4.2 mtime+size short-circuit

Hashing every file on every scan and read is wasteful. The `files` table stores `mtime` and `size_bytes` alongside `file_hash`. The check order everywhere is:

1. `stat` the file.
2. If `mtime` **and** `size_bytes` match the stored values → treat as unchanged, **skip hashing**.
3. Otherwise compute SHA-256 and compare with the stored digest; only a digest mismatch marks the file `changed` (a touched-but-identical file just gets its stored `mtime` refreshed).

`scan` accepts `verify: true` to force full hashing of every candidate file, bypassing the short-circuit (paranoia mode for clock-skew or backup-restore situations).

### 4.3 Where change detection runs

| Trigger | Mechanism | Result |
|---------|-----------|--------|
| `scan` | Walk tree, short-circuit check per file | `added` / `changed` / `deleted` lists + indexing plan |
| Any file-scoped read (`get-file`, `get-files`, `search`, `overview`, `dependents`, `dependencies`, `references`, `annotations`, `find-symbol`) | Short-circuit check on returned files only | Top-level `needs_reindex: [{path, reason}]` array; `analysis_status` set to `stale` in the DB |
| Deletion | `scan` with `remove_deleted: true` (default) | Rows, child rows (CASCADE) and FTS entries removed |

`reason` is `"changed"` (content differs) or `"missing_layer"` (row exists but a requested layer was never populated). This is v1 behavior, kept as-is — it satisfies the requirement that *an operation returns the list of changed files* (`scan`) and that staleness is visible on every read.

---

## 5. Layered Information Model (v2)

Five layers per file. Consumers pick the cheapest layer that answers their question.

| Layer | Name | Producer | Typical tokens | Contents |
|------:|------|----------|---------------:|----------|
| 0 | Metadata | **MCP** (deterministic) | 30–60 | path, name, file_type, language, size_bytes, line_count, word_count, file_hash, mtime, indexed_at, analysis_status |
| 1 | Summary + tags | **Agent** (Haiku) | 30–60 | one-sentence `summary`, 5–10 semantic `tags` |
| 2 | Structure | **MCP (`analyzer`) for Dart; agent for other languages** | 100–400 | symbols **with line ranges**, imports, external references (dot-paths), annotations |
| 3 | Symbol summaries | **Agent** (Haiku) | 200–800 | one-sentence description per public symbol |
| 4 | Public API | Derived | 50–200 | layer 2 filtered to `visibility = "public"` |

Layer 5 remains the raw file — never stored; `filesystem read-file` (ideally with `startLine`/`endLine` from layer 2 line ranges) is the escape hatch.

Changes vs v1:

- **Layer 2 has two producers, chosen per file.** For Dart files the MCP extracts structure itself: syntactic analysis yields declarations with **exact 1-indexed line ranges** (declaration start to end of body), resolved analysis yields **dot-path external references** (§8.4), and a regex pass yields annotations. Agent-supplied structural fields on Dart records are ignored. For every other language, the agent supplies structure from the line-numbered `read-file` output, and the MCP normalizes it into the same tables.
- **Layer 0 is always MCP-computed** during `index-files` (and hash/mtime refreshed during scans). This directly satisfies the "simple operations such as line count" requirement — line/word/size counts are always available without touching the agent.
- **Layer 1 gains `tags`.** See §8.2.
- **Layer 2 symbols gain `line` / `end_line`** — analyzer-exact for Dart, agent-derived elsewhere.
- **Visibility is an explicit per-symbol field** (`public` | `private`): derived deterministically for Dart (`_` prefix), judged by the agent for other languages using that language's conventions.

`layers_present` is derived at write time: 0 always; 1 if `summary` was supplied; 2 if structure was written (always true for Dart — the MCP computes it); 3 if any symbol summary was supplied. Layer 4 is a view and is never stored.

---

## 6. Database Schema (v2)

```sql
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
PRAGMA user_version=2;

-- One row per indexed file
CREATE TABLE files (
  id              TEXT PRIMARY KEY,          -- uuid v4
  path            TEXT NOT NULL UNIQUE,      -- relative to project root, '/'-separated
  name            TEXT NOT NULL,             -- basename
  file_type       TEXT,                      -- extension without dot: 'dart', 'yaml', ...
  language        TEXT,                      -- agent-reported, falls back to extension map
  file_hash       TEXT NOT NULL,             -- sha256 hex of content bytes
  size_bytes      INTEGER NOT NULL,
  line_count      INTEGER NOT NULL,
  word_count      INTEGER NOT NULL,
  mtime           TEXT NOT NULL,             -- ISO 8601 UTC
  summary         TEXT,                      -- layer 1
  tags            TEXT,                      -- layer 1: JSON array of lowercase keywords
  layers_present  TEXT NOT NULL,             -- JSON array, e.g. "[0,1,2,3]"
  indexed_at      TEXT,                      -- last successful index write
  structure_refreshed_at TEXT,               -- last dependent-refresh of references (§8.5)
  analysis_status TEXT NOT NULL DEFAULT 'pending',  -- 'fresh' | 'stale' | 'pending' | 'failed'
  analysis_error  TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);
CREATE INDEX idx_files_path     ON files(path);
CREATE INDEX idx_files_name     ON files(name);
CREATE INDEX idx_files_type     ON files(file_type);
CREATE INDEX idx_files_language ON files(language);
CREATE INDEX idx_files_status   ON files(analysis_status);

-- Layer 2/3: every declaration found (merges v1's exports + variables)
CREATE TABLE symbols (
  id         TEXT PRIMARY KEY,
  file_id    TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  kind       TEXT NOT NULL,        -- see vocabulary below
  visibility TEXT NOT NULL DEFAULT 'public',   -- 'public' | 'private'
  parent     TEXT,                 -- enclosing symbol name (class for methods, etc.)
  signature  TEXT,                 -- compact, e.g. "(Duration ttl) -> Future<Session>"
  line       INTEGER,              -- 1-indexed start line
  end_line   INTEGER,              -- 1-indexed inclusive end line
  summary    TEXT,                 -- layer 3
  created_at TEXT NOT NULL
);
CREATE INDEX idx_symbols_file ON symbols(file_id);
CREATE INDEX idx_symbols_name ON symbols(name);
CREATE INDEX idx_symbols_kind ON symbols(kind);

-- Layer 2: import statements, verbatim
CREATE TABLE imports (
  id          TEXT PRIMARY KEY,
  file_id     TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  import_path TEXT NOT NULL,
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_imports_file ON imports(file_id);
CREATE INDEX idx_imports_path ON imports(import_path);

-- Layer 2: external symbols this file uses, in dot-path notation (carried over from v1)
CREATE TABLE symbol_references (
  id          TEXT PRIMARY KEY,
  file_id     TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  symbol      TEXT NOT NULL,        -- 'Widget'
  module      TEXT NOT NULL,        -- 'flutter' | 'dart' | this project's package name | agent-derived
  source_path TEXT,                 -- dotted path inside the module: 'material', 'src.widgets.framework'
  dot_path    TEXT NOT NULL,        -- '<module>.<source_path>.<symbol>' — always populated
  symbol_kind TEXT,                 -- class, function, method, variable, enum, typedef, mixin, extension, unknown
  resolution  TEXT NOT NULL,        -- 'resolved' (analyzer) | 'declared' (agent best-effort)
  count       INTEGER NOT NULL DEFAULT 1,
  created_at  TEXT NOT NULL,
  UNIQUE(file_id, dot_path)
);
CREATE INDEX idx_refs_symbol   ON symbol_references(symbol);
CREATE INDEX idx_refs_module   ON symbol_references(module);
CREATE INDEX idx_refs_dot_path ON symbol_references(dot_path);

-- Layer 2: TODO/FIXME/HACK/NOTE/DEPRECATED
CREATE TABLE annotations (
  id         TEXT PRIMARY KEY,
  file_id    TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL,
  message    TEXT,
  line       INTEGER,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_annotations_file ON annotations(file_id);
CREATE INDEX idx_annotations_kind ON annotations(kind);

-- Full-text search (manually synced inside the same transaction as row writes)
CREATE VIRTUAL TABLE code_index_fts USING fts5(
  file_id UNINDEXED,
  path,
  name,
  summary,
  tags,
  symbol_names,
  symbol_summaries,
  reference_symbols          -- space-joined dot_paths; FTS tokenizer splits on '.', so
);                           -- 'Widget', 'material' and 'flutter' all match
```

Notes:

- **`symbols` merges v1's `exports` and `variables` tables** — a variable is just `kind='variable'`. v1's naming was acknowledged as misleading; v2 fixes it.
- **`symbol_references` carries v1's `external_symbol_usages` dot-path model forward** (same `<module>.<source_path>.<symbol>` canonicalization — see §8.4). The new `resolution` column records provenance: `resolved` rows come from the Dart analyzer and are precise; `declared` rows come from the agent for other languages and are best-effort. Queries can filter on it when precision matters.
- **`dot_path` is always populated.** For `declared` rows the MCP normalizes the agent's `qualifier` string deterministically (e.g. `package:http/http.dart` → module `http`, source_path `http`; a bare module name → `<module>.<symbol>`; nothing usable → `unknown.<symbol>`). Uniform shape keeps `UNIQUE(file_id, dot_path)`, the FTS column, and dot-path queries working identically for every language.
- **Symbol kind vocabulary** (extractor and agent choose from): `class`, `interface`, `mixin`, `enum`, `function`, `method`, `constructor`, `getter`, `setter`, `variable`, `constant`, `typedef`, `extension`, `key` (config entries), `section` (markdown/doc headings), `other`.
- **Line-range sanity check:** on write, the MCP clamps/flags agent-supplied `line`/`end_line` values that exceed the file's `line_count` (sets them to NULL and records a warning in the response) so hallucinated ranges never poison partial reads. Analyzer-produced ranges are exact by construction.

---

## 7. Operation Surface

Single MCP tool `code-index`, multiplexed by `operation`, `project_dir` required on every call (consistent with `filesystem`, `git`, `planner`). 14 operations:

| Op | Kind | Purpose |
|----|------|---------|
| `scan` | scan | Walk tree, detect added/changed/deleted, return indexing plan |
| `index-files` | write | Batched write of records (1..N files); triggers dependent refresh (§8.5) |
| `get-file` | read | One file, selected layers |
| `get-files` | read | Batched `get-file` |
| `overview` | read | Compact listing: path + summary + tags + public symbol names |
| `search` | search | FTS5 across names, paths, summaries, tags, symbols, references |
| `find-symbol` | search | Symbol lookup → path + line range (the "jump to definition" op) |
| `references` | search | Which files use symbol X (dot-path queries) |
| `dependents` | search | Which files import path Y |
| `dependencies` | search | What does file Y import (internal/external classified) |
| `annotations` | search | TODO/FIXME/HACK/NOTE/DEPRECATED queries |
| `stats` | read | Aggregate counts, tag cloud, freshness summary |
| `project-info` | util | Data dir, db path, registry entry, schema version, last scan |
| `is-allowed` | util | Allowed-paths check for a path |

### 7.1 `scan`

Parameters: `directories` (default `["."]`), `extensions` (e.g. `[".dart", ".yaml"]`), `since` (ISO 8601 mtime pre-filter), `rebuild` (drop + recreate DB, default false), `remove_deleted` (default true), `verify` (force full hashing, default false).

```json
{
  "added": ["lib/new.dart", "tool/build.yaml"],
  "changed": ["lib/touched.dart"],
  "deleted": ["lib/gone.dart"],
  "unchanged_count": 214,
  "skipped_by_since": 0,
  "out_of_scope": ["scripts/build.sh"],
  "plan": [
    { "path": "lib/new.dart", "needs": [1, 3] },
    { "path": "lib/touched.dart", "needs": [1, 3] },
    { "path": "tool/build.yaml", "needs": [1, 2, 3] }
  ],
  "summary": { "files_to_index": 3, "estimated_batches": 1 }
}
```

`plan[].needs` lists the **agent-produced** layers wanted, and is language-aware: Dart files get `[1, 3]` because the MCP computes their layer 2 itself during `index-files`; other files get `[1, 2, 3]`. Layer 0 is always computed by the MCP on write. The parent hands the whole response to `code-index-agent`. This operation is the v2 home of the v1 `auto-scan` + `diff` pair — one op instead of two; the `changed`/`added`/`deleted` arrays satisfy the "list changed files" requirement directly.

### 7.2 `index-files`

The single write path. Parameters: `files` — an array of 1..N records — and `refresh_dependents` (default `true`, see §8.5). Record shape differs by extraction route:

```json
{
  "files": [
    {
      "path": "lib/src/auth/session.dart",
      "language": "dart",
      "summary": "Manages login sessions: creation, refresh and expiry.",
      "tags": ["auth", "session", "login", "token", "expiry", "refresh"],
      "symbol_summaries": {
        "SessionManager": "Owns the active session lifecycle.",
        "SessionManager.refresh": "Extends the session or throws SessionExpired."
      }
    },
    {
      "path": "tool/build.yaml",
      "language": "yaml",
      "summary": "Build targets and code generation options for build_runner.",
      "tags": ["build", "codegen", "build-runner", "config"],
      "symbols": [
        { "name": "targets", "kind": "key", "visibility": "public", "line": 1, "end_line": 14 }
      ],
      "imports": [],
      "references": [
        { "symbol": "json_serializable", "qualifier": "build_runner", "count": 1 }
      ],
      "annotations": []
    }
  ]
}
```

Per record, the MCP:

1. Validates the path (exists, allowed) and computes layer 0 (stat, SHA-256, line/word counts).
2. **Dart files:** runs the extractor against the warm analysis context — syntactic declarations (exact line ranges, `_`-prefix visibility), resolved external references as dot-paths (`resolution='resolved'`), regex annotations. Agent-supplied `symbols`/`imports`/`references`/`annotations` arrays are ignored for Dart; `symbol_summaries` (keys: `Name` or `Parent.name`) are applied to the matching extracted symbols.
3. **Other files:** stores the agent-supplied structure; normalizes each `references[]` entry into dot-path form (`resolution='declared'`); sanity-checks line ranges; `symbol_summaries` map is also accepted as an alternative to inline `symbols[].summary`.
4. Derives `layers_present`, then **replaces** the file's rows transactionally (§8.5.1) and syncs the FTS row.
5. After the batch: refreshes references of dependents of changed Dart files (§8.5.3) unless `refresh_dependents: false`.

Only `path` is required — a record with just `path` still refreshes layer 0 (and, for Dart, layer 2: structure needs no LLM input).

Response:

```json
{
  "indexed": ["lib/src/auth/session.dart", "tool/build.yaml"],
  "failed": [{ "path": "lib/broken.dart", "error": "File not found" }],
  "warnings": [{ "path": "tool/build.yaml", "warning": "end_line 300 > line_count 14; range cleared for symbol 'targets'" }],
  "dependents_refreshed": ["lib/src/auth/login_controller.dart"],
  "summary": { "indexed": 2, "failed": 1, "dependents_refreshed": 1 }
}
```

Batching (5–10 files per call) replaces v1's one `auto-index` call per file — fewer round trips, and each file still commits independently so one bad record cannot poison a batch.

### 7.3 `get-file` / `get-files`

Parameters: `path` (or `paths`), `layers` (default `[0, 1, 4]`). Layer semantics per §5; requesting layer 2 or 3 returns symbols (with line ranges), imports, references (dot-paths + resolution), annotations; layer 4 filters symbols/references to `visibility='public'`. Response carries `needs_reindex` (§4.3).

### 7.4 `overview`

Parameters: `path_pattern`, `file_type`, `language`, `limit`. Returns, per file: `path`, `summary`, `tags`, `line_count`, and public symbol names — the cheapest way to orient in an unfamiliar area of the codebase.

### 7.5 `search`

Parameters: `query` (FTS5 match across all FTS columns; tokens are OR-joined with prefix matching, BM25 ranked — v1 semantics kept), plus AND-filters: `file_type`, `language`, `path_pattern`, `tag` (exact tag match), `symbol_name`, `symbol_kind`, `import_pattern`, `limit` (default 25). Returns compact hits: `path`, `summary`, `tags`, matched public symbols. Falls back to LIKE search if the FTS query is malformed (v1 behavior kept). Because `reference_symbols` holds dot-paths, a query like `material` finds every file importing from `flutter.material.*`.

### 7.6 `find-symbol`

Parameters: `name`, `match` (`exact` | `prefix`, default `exact`), `kind`, `visibility`, `path_pattern`, `limit` (default 25).

```json
{
  "matches": [
    { "path": "lib/src/auth/session.dart", "name": "refresh", "kind": "method",
      "parent": "SessionManager", "visibility": "public",
      "signature": "(Duration ttl) -> Future<Session>",
      "line": 57, "end_line": 74,
      "summary": "Extends the session or throws SessionExpired." }
  ],
  "count": 1,
  "needs_reindex": []
}
```

This is the new headline operation: symbol → exact file + line range → `filesystem read-file startLine=57 endLine=74`. For Dart the ranges are analyzer-exact. A consumer answers "how does refresh work?" for ~20 source lines instead of a whole file.

### 7.7 `references`

Parameters (v1's `usages` surface, kept): `symbol` (exact), `module`, `source_path`, `dot_path_pattern` (LIKE), `kind`, `resolution` (`resolved` | `declared`), `path_pattern`, `limit`.

```json
{
  "matches": [
    { "path": "lib/src/ui/login_screen.dart",
      "dot_path": "flutter.material.Widget", "symbol": "Widget",
      "module": "flutter", "source_path": "material",
      "kind": "class", "resolution": "resolved", "count": 7 }
  ],
  "count": 1,
  "needs_reindex": []
}
```

Ordered by `count` descending. "Which files use `Widget` from material?" remains a precise, resolved query for Dart — exactly as in v1.

### 7.8 `dependents` / `dependencies`

Unchanged in spirit from v1. `dependents(path)` matches `imports.import_path` by suffix/normalized comparison and returns importing files. `dependencies(path)` returns the file's imports classified `internal` (resolves to an indexed file) or `external`. `dependents` is also the mechanism behind the §8.5 dependent refresh.

### 7.9 `annotations`

Parameters: `kind`, `message_pattern`, `path_pattern`, `file_type`, `limit`. Returns entries with `by_kind` counts.

### 7.10 `stats`

Aggregates: files by language and type, symbols by kind, top imports, top referenced dot-paths, annotations by kind, **top 20 tags** (the tag cloud doubles as a vocabulary hint for `search`), freshness (`fresh`/`stale`/`pending`/`failed` counts), total line/word counts, db file size. No hash checks (counts only).

### 7.11 `project-info`

Returns: canonical project path, data directory, db path, `registry.json` entry, schema version, row counts, `last_scan_at`. Primarily for debugging and for the skill to verify the index exists before advising a full scan.

### 7.12 `is-allowed`

Unchanged from v1: checks a path against the `code-index` allowed paths from `jhsware-code.yaml`.

---

## 8. Search & Reference Design

### 8.1 FTS5 baseline

FTS5 with OR-joined prefix tokens and BM25 ranking carries over from v1 — it proved adequate for keyword search. The FTS row per file concatenates: path, name, summary, tags, symbol names, symbol summaries, and reference dot-paths. The default tokenizer splits on non-alphanumeric characters, so dot-paths make every component searchable: `Widget`, `material`, and `flutter` all hit `flutter.material.Widget`.

### 8.2 Semantic tags

The concept-search gap identified in `vector-search-research.md` ("auth" should find "login") is closed the lightweight way: the indexing agent emits **5–10 lowercase concept keywords** per file while it is already reading the file for summarization — near-zero marginal cost. Guidance for tag quality lives in the agent contract (`design-v2-agent-and-skill.md`); in short: domain concepts, synonyms of the file's own terminology, architectural role (`repository`, `http-client`, `migration`), not restatements of the filename.

Tags are stored as a JSON array on `files.tags` and flattened into the `tags` FTS column. `search` matches them via the general `query` and via the exact `tag` filter; `stats` exposes the top-tag cloud so consumers can discover the vocabulary.

### 8.3 Embeddings — explicitly out of scope

Per the standing recommendation in `vector-search-research.md`: no vector search. The Dart CLI embedding ecosystem is immature, external embedding APIs add key-management friction, and tags + FTS5 cover the realistic gap. Revisit only if tag-based search demonstrably falls short.

### 8.4 Resolved dot-paths — the precision model

v1's headline accuracy feature is kept in full: for Dart files, external references are produced by the analyzer's **resolved** mode and canonicalized into dot-path notation:

```
<module>.<source_path>.<symbol>
```

| Source | Dot path |
|--------|----------|
| `Widget` from `package:flutter/material.dart` | `flutter.material.Widget` |
| `File` from `dart:io` | `dart.io.File` |
| `MyService` from `lib/services/my_service.dart` (this project, package `myapp`) | `myapp.lib.services.my_service.MyService` |

Every identifier's `Element` → `LibraryElement` → `source.uri` chain gives the true defining library, regardless of how it was imported (shows, hides, prefixes, re-exports). This is what makes "which files use `Widget` *from material*" precise, and it cannot be replicated by regex or by an LLM reading one file at a time.

What changed vs v1 is the **cost model**, not the accuracy:

- **Warm context.** v1 built an `AnalysisContextCollection` per `auto-index` call — seconds of overhead per file. v2 keeps **one lazily-built context per project per server process**, notifies it of file changes (`changeFile` + `applyPendingFileChanges`), and resolves incrementally: a few seconds once, then tens of milliseconds per file.
- **Batch amortization.** `index-files` resolves all Dart files of a batch against the same warm context in one pass.
- **Uniform table.** Resolved rows (`resolution='resolved'`) and agent-declared rows for other languages (`resolution='declared'`, normalized to the same dot-path shape) live in one `symbol_references` table, so every query works across the whole codebase; the `resolution` filter isolates precise results when it matters.

Non-Dart languages get best-effort declared references — the same fidelity v1 had for them. If another language ever needs resolved precision, the extractor seam in §2 (principle 2) is where its tooling plugs in without schema or API changes.

### 8.5 Reference lifecycle — correctness on re-index

References must stay consistent as files change. Three mechanisms, in increasing scope:

**8.5.1 Per-file transactional replace.** Any write for file F (agent record or MCP structure refresh) runs as one transaction: delete all of F's child rows (`symbols`, `imports`, `symbol_references`, `annotations`) and its FTS row, re-insert the new state, update the `files` row. No stale rows can survive a re-index, readers never observe a half-updated file (WAL snapshot isolation), and a failed write rolls back to the previous consistent state — `analysis_status='failed'` + `analysis_error` record the failure.

**8.5.2 Deletion.** `scan` with `remove_deleted: true` removes the `files` row (child rows cascade via `ON DELETE CASCADE`) and deletes the FTS row in the same transaction. References *to* a deleted file's symbols held by other files remain until those files are refreshed — see next.

**8.5.3 Dependent refresh (cross-file consistency).** When file A changes, files that import A may now resolve differently — A may have renamed, moved, or removed symbols they use. Their own content hasn't changed, so hashing will never flag them. v2 closes this gap **without the agent**, exploiting the fact that Dart layer 2 is MCP-computed:

1. After an `index-files` batch commits, collect the batch's changed Dart files.
2. Find their direct dependents via the `imports` table (project-internal importers only), excluding files already in the batch.
3. For each dependent: re-run resolved extraction against the warm context (it already knows A changed), and replace only its `symbol_references` rows + FTS `reference_symbols` column, transactionally per file. Layers 1/3 are untouched — the file's content didn't change, so its summaries are still valid. `structure_refreshed_at` is stamped.
4. Report them in `dependents_refreshed` so the caller sees what was touched.

Cost: analyzer-only, tens of milliseconds per dependent, zero LLM tokens. Scope is deliberately bounded to *direct* dependents — transitive resolution changes surface the next time those files are scanned or read, and in practice a symbol rename lands together with edits to the files that use it (which flags them as `changed` anyway). `refresh_dependents: false` opts out for bulk initial indexing, where every file is in the plan anyway.

**8.5.4 Declared references.** For non-Dart files, references refresh whenever their own file is re-indexed (8.5.1). Cross-file drift for declared rows is accepted best-effort — same as v1.

---

## 9. Roles

| Component | Role | Contract |
|-----------|------|----------|
| `code_index` MCP | Durable store + query engine. Computes layer 0 for every file and layer 2 for Dart via a warm `package:analyzer` context (resolved dot-paths); normalizes declared references; owns the reference lifecycle (§8.5). Never calls an LLM. | This document |
| `code-index-agent` (Haiku) | Disposable worker. Reads files via `filesystem`, produces layers 1+3 for every file and layer 2 for non-Dart files, writes via `index-files`. | `design-v2-agent-and-skill.md` §Agent |
| `code-index` skill | Consumer-side query guide for parent agents: cheap-first querying, the find-symbol → partial-read pattern, needs_reindex policy, when to spawn the agent. | `design-v2-agent-and-skill.md` §Skill |

The v1 execution model is kept: **pull-based** (Model A). The parent runs `scan`, hands the plan to the agent, the agent writes back through `index-files`. The MCP never spawns anything.

---

## 10. End-to-End Flows

### 10.1 Session start

```
parent → code-index: scan
         ← { added: [...], changed: [...], plan: [12 files: dart→needs [1,3], other→needs [1,2,3]] }
parent → spawn code-index-agent with the scan response
         (agent: read-files in batches of 5–10 → index-files per batch;
          MCP computes Dart structure + resolved references during each write)
         ← { indexed: 12, failed: [], out_of_scope: [] }
```

### 10.2 Token-efficient drill-down (headline pattern)

```
parent → code-index: search query="session refresh expiry"        (~200 tokens)
         ← hits: lib/src/auth/session.dart (summary, tags, symbols)
parent → code-index: find-symbol name="refresh" path_pattern="auth"
         ← { path: "lib/src/auth/session.dart", line: 57, end_line: 74 }
parent → filesystem: read-file path=... startLine=57 endLine=74   (~150 tokens)
```

Total: ~400 tokens to reach the exact 18 lines that matter, vs ~3000+ for reading the file.

### 10.3 Changed file, references kept consistent

```
(lib/src/auth/session.dart was edited: `refresh` renamed to `renew`)

parent → code-index: scan
         ← { changed: ["lib/src/auth/session.dart"], plan: [{ path: ..., needs: [1, 3] }] }
parent → spawn code-index-agent with the plan
         agent → code-index: index-files files=[{ path: "lib/src/auth/session.dart", summary: ..., tags: ..., symbol_summaries: ... }]
                 (MCP re-extracts structure, replaces all child rows transactionally,
                  then re-resolves direct dependents' references — no Haiku involved)
         ← { indexed: [...], dependents_refreshed: ["lib/src/auth/login_controller.dart"] }

parent → code-index: references symbol="renew"
         ← up-to-date matches, including login_controller.dart
```

### 10.4 Out-of-scope file

```
parent → code-index: get-file path="scripts/build.sh"
         ← { status: "out_of_scope", allowed_paths: ["lib", "test", "bin", "pubspec.yaml"] }
parent → filesystem: read-file path="scripts/build.sh"   (parent handles it itself)
```

---

## 11. Security & Scope

- **Allowed paths:** unchanged from v1. `ProjectConfigService.getAllowedPaths(projectDir, 'code-index')` reads `jhsware-code.yaml`; every path-taking operation enforces it; tree walks emit `out_of_scope` arrays; missing config falls back to full project access (matching `filesystem`/`git`).
- **Path normalization:** all incoming paths are normalized and must resolve inside the project root — `../` escapes are rejected before any allowed-path check.
- **Registry trust:** `~/.code-index` only ever contains data for projects registered via `--project-dir`; the server refuses operations for unregistered projects (same validation pattern as the other MCP servers in this suite).
- **Server arguments:** `--project-dir=PATH` (repeatable, required), `--data-root=PATH` (optional, default `~/.code-index`). `--planner-data-root` is gone — code_index no longer depends on planner infrastructure.

---

## 12. Performance & Resource Budget

| Cost | v2 behavior |
|------|-------------|
| Scan, unchanged project | stat-walk only (mtime+size short-circuit) — no hashing, no writes. O(files) stats; ~1–2s for 5k files. |
| Scan, changed files | SHA-256 only for stat-mismatched files; <1ms per typical source file. |
| Read ops | stat check per returned file; hash only on stat mismatch. Negligible. |
| Analyzer context | One warm `AnalysisContextCollection` per project per server process, built lazily on the first Dart write (~2–5 s mid-size project), kept in sync via `changeFile`/`applyPendingFileChanges`. Resolution: tens of ms per file. v1 paid the context build per call; v2 pays it once per session. |
| Dependent refresh | Analyzer-only re-resolution of direct dependents of changed Dart files; tens of ms each, zero LLM tokens. |
| Indexing tokens | ~1 Haiku completion per 5–10-file batch. Dart files need no agent layer 2 — smaller records than v1's non-Dart path. Only added/changed files are ever re-indexed. |
| Index size | ~2–5 KB of row data per file; a 1k-file project ≈ a few MB. |
| Concurrency | WAL + busy_timeout=5000 (multiple MCP server processes may share a project DB safely; single-writer per transaction). Each process holds its own analyzer context. |

---

## 13. Migration from v1

Clean break, no data migration:

1. v1 databases under `[planner-data-root]/projects/*/db/code_index.db` are simply abandoned in place (they are disposable caches). They can be deleted manually by the user whenever convenient — the tool never deletes them.
2. First `scan` against a project creates `~/.code-index/<basename>-<hash8>/`, registers it in `registry.json`, and reports every file as `added`.
3. One full agent indexing pass rebuilds the index. Cost: one Haiku batch call per 5–10 files, once; Dart structure and resolved references are recomputed by the MCP for free.
4. Operation renames for consumers: `auto-scan`+`diff` → `scan`; `auto-index` → `index-files`; `usages` → `references` (same dot-path query parameters); `search-annotations` → `annotations`; `overview`/`get-file`/`get-files`/`search`/`dependents`/`dependencies`/`stats`/`is-allowed` keep their names. The skill and agent are rewritten in the same change, so no consumer sees a mixed vocabulary.

---

## 14. Testing Strategy

- **Unit:** hash utils (sha256 + short-circuit logic), registry/meta read-modify-write + atomic rename, schema create/rebuild, per-operation handlers (validation, allowed-paths, layer filtering, FTS sync, line-range clamping), declared-reference dot-path normalization.
- **Dart extractor:** port the v1 `dart_parser_test.dart` expectations to the v2 extractor (declaration parity), add exact line-range assertions, dot-path canonicalization cases (package/dart/relative imports, prefixed imports, re-exports), and warm-context incrementality (change a file, re-resolve, no full rebuild).
- **Fixtures:** extend `test/fixtures/sample_project` with non-Dart files (yaml, md, js) since v2 indexes every language through the same record shape.
- **Integration:** the §10 flows end-to-end against a temp `--data-root`; collision test (two projects with the same basename get distinct directories); registry rebuild after deletion; stale-on-read after touching a fixture file; `rebuild: true` round trip; **dependent-refresh test:** rename a symbol in fixture file A, re-index A, assert B's `symbol_references` rows now show the new dot-path and `dependents_refreshed` lists B.
- **Concurrency smoke test:** two connections writing/reading under WAL.

---

## 15. Implementation Plan

1. **Storage foundation** — data-root resolution, `<basename>-<hash8>` derivation, `registry.json` + `meta.json` with atomic writes, SHA-256 hash utils with mtime+size short-circuit, clean-rebuild schema v2. `pubspec.yaml`: drop `xxh3`, keep `analyzer`, add `crypto`.
2. **Dart extractor** — port v1's `dart_parser.dart`/`DartResolvedParser` onto a **warm per-project `AnalysisContextCollection`**: syntactic declarations with exact line ranges + visibility, resolved dot-path references, regex annotations; `changeFile`-based incremental updates.
3. **Write path** — `index-files`: record validation, layer-0 computation, Dart-vs-agent routing, `symbol_summaries` application, declared-reference normalization, `layers_present` derivation, line-range sanity checks, transactional replace + FTS sync (§8.5.1), **dependent refresh** (§8.5.3).
4. **Scan** — walk + short-circuit diff + language-aware plan (`since`, `rebuild`, `remove_deleted`, `verify`, `extensions`).
5. **Read path** — `get-file`/`get-files` (layers), `overview`, `project-info`, stale detection (`needs_reindex`).
6. **Search family** — `search` (FTS + filters + LIKE fallback), `find-symbol`, `references` (dot-path params + `resolution` filter), `dependents`, `dependencies`, `annotations`, `stats`.
7. **MCP wiring** — tool registration/schema, `--data-root` argument, help text, remove `--planner-data-root`.
8. **Tests** — per §14.
9. **Agent rewrite** — `agentic-plugins/jhsware-code/agents/code-index-agent.md` per the v2 contract.
10. **Skill rewrite** — `agentic-plugins/jhsware-code/skills/code-index/SKILL.md` per the v2 contract.
11. **Docs** — package README, CHANGELOG; keep this document in sync with as-built decisions.

---

## 16. Open Questions

- **Tag vocabulary drift.** Different Haiku versions may tag differently over time; mixed vocabularies degrade tag search slightly. Default position: acceptable (tags are additive to FTS keywords); revisit a `reindex-tags` maintenance flow only if observed in practice.
- **`registry.json` concurrent writers.** Two server processes starting simultaneously could race the registry write. Atomic rename makes the loser's write win harmlessly (both entries are deterministic and identical in content except timestamps). A lock file is deliberately omitted until a real problem appears.
- **Symbol cap.** Very large generated files could produce thousands of symbols. Proposed default: extractor/agent caps at 150 symbols/file and sets a `truncated` marker; MCP stores it on `files.analysis_error` as an informational note. To be validated during implementation.
- **Analyzer upgrades.** A major `analyzer` version bump can change resolution output. Policy: bump the schema `user_version` when extractor output changes materially, forcing a clean rebuild instead of a mixed-precision index (§3.4).
- **Analyzer context memory.** A warm context for a very large project holds noticeable memory in the server process. If this becomes a problem, add an idle-eviction timer (drop the context after N minutes without Dart writes; it rebuilds lazily). Not built until needed.
