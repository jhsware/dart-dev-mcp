# Code Index v2 — Architecture & Design

**Status:** Approved design — implementation not started
**Date:** 2026-07-03
**Author:** sebastian@urbantalk.se
**Supersedes:** `architecture-mcp-persistent-haiku-agent.md` (v1 as-built, 2026-05-26)
**Related:** `vector-search-research.md` (2026-02-14), `design-v2-agent-and-skill.md` (contracts for the Haiku agent and the consumer skill)

---

## 1. Purpose

`code_index` is an MCP server that maintains a persistent, layered SQLite index of the files in a project so that agents can explore and search a codebase without reading raw source into their context window. A Haiku-backed worker agent (`code-index-agent`) reads files via the `filesystem` tool and writes summaries and structure into the index; consumer agents query the index through cheap, targeted operations.

v2 is a full rewrite. It keeps the ideas that proved out in v1 (layered storage, hash-based change detection, stale-on-read, plan-driven indexing, FTS5 search, allowed-paths scoping) and changes four fundamentals:

| # | Decision (design review 2026-07-03) | v1 | v2 |
|---|--------------------------------------|----|----|
| 1 | **Storage location** | `[planner-data-root]/projects/[name]/db/code_index.db` — coupled to planner infrastructure | `~/.code-index/<basename>-<hash8>/code_index.db` — standalone, plus a central `registry.json` |
| 2 | **Change detection hash** | XXH3-64 | **SHA-256** with an mtime+size short-circuit |
| 3 | **Structural extraction** | `package:analyzer` for Dart (syntactic + resolved), agent for other languages | **Agent-only, language-agnostic.** The MCP is a pure store/query engine; the Haiku agent extracts structure for every language. `analyzer` and `xxh3` dependencies are dropped. |
| 4 | **Semantic search** | FTS5 keywords only | FTS5 **plus Haiku-generated semantic tags** per file (the lightweight path recommended in `vector-search-research.md`) |

Two further v2 additions that fall out of the rewrite:

- **Symbols carry line ranges** (`line`, `end_line`), enabling the headline token-saving pattern: `find-symbol` → `filesystem read-file startLine/endLine` — read 20 lines instead of 500.
- **Batched writes** (`index-files`) replace the per-file `auto-index` call, cutting MCP round trips during indexing.

---

## 2. Architectural Principles

1. **MCP is the durable layer.** All persistent state lives in per-project SQLite databases under `~/.code-index`. Nothing important lives in any agent's context window.
2. **The MCP is language-agnostic.** It computes only deterministic filesystem facts (layer 0) itself. Everything language-shaped — symbols, imports, references, summaries, tags — is supplied by the indexing agent. The MCP validates and stores; it never parses source.
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

Kept from v1. The schema version is stored in `PRAGMA user_version` (mirrored in `meta.json` for human inspection). On open, if `user_version` differs from the expected version, the database file and its WAL/SHM sidecars are deleted and recreated with the current schema. The next `scan` reports every file as `added`, triggering a full re-index. No migration machinery exists.

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
| Deletion | `scan` with `remove_deleted: true` (default) | Rows and FTS entries removed |

`reason` is `"changed"` (content differs) or `"missing_layer"` (row exists but a requested layer was never populated). This is v1 behavior, kept as-is — it satisfies the requirement that *an operation returns the list of changed files* (`scan`) and that staleness is visible on every read.

---

## 5. Layered Information Model (v2)

Five layers per file. Consumers pick the cheapest layer that answers their question.

| Layer | Name | Producer | Typical tokens | Contents |
|------:|------|----------|---------------:|----------|
| 0 | Metadata | **MCP** (deterministic) | 30–60 | path, name, file_type, language, size_bytes, line_count, word_count, file_hash, mtime, indexed_at, analysis_status |
| 1 | Summary + tags | **Agent** (Haiku) | 30–60 | one-sentence `summary`, 5–10 semantic `tags` |
| 2 | Structure | **Agent** (Haiku) | 100–400 | symbols **with line ranges**, imports, external references, annotations |
| 3 | Symbol summaries | **Agent** (Haiku) | 200–800 | one-sentence description per symbol |
| 4 | Public API | Derived | 50–200 | layer 2 filtered to `visibility = "public"` |

Layer 5 remains the raw file — never stored; `filesystem read-file` (ideally with `startLine`/`endLine` from layer 2 line ranges) is the escape hatch.

Changes vs v1:

- **Layer 0 is the only MCP-computed layer.** The MCP computes it during `index-files` (and refreshes hash/mtime during scans). This directly satisfies the "simple operations such as line count" requirement — line/word/size counts are always available without touching the agent.
- **Layer 1 gains `tags`.** See §8.2.
- **Layer 2 is agent-supplied for every language** — including Dart. The resolved dot-path notation from v1 is replaced by a simpler, language-neutral `references` model (§6, §8.4).
- **Layer 2 symbols gain `line` / `end_line`**, sourced from the line-numbered output of `filesystem read-file`.
- **Visibility is an explicit per-symbol field** (`public` | `private`) judged by the agent using the conventions of each language, instead of v1's Dart-specific `_`-prefix heuristic applied at read time.

`layers_present` is derived at write time from what the agent actually supplied: 0 always; 1 if `summary` present; 2 if `symbols`/`imports` present; 3 if any symbol has a `summary`. Layer 4 is a view and is never stored.

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
  indexed_at      TEXT,                      -- last successful agent write
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

-- Layer 2/3: every declaration the agent found (merges v1's exports + variables)
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

-- Layer 2: external symbols this file uses (agent best-effort, language-neutral)
CREATE TABLE symbol_references (
  id         TEXT PRIMARY KEY,
  file_id    TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  symbol     TEXT NOT NULL,        -- e.g. 'Client'
  qualifier  TEXT,                 -- import path or module the agent attributes it to
  count      INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  UNIQUE(file_id, symbol, qualifier)
);
CREATE INDEX idx_refs_symbol    ON symbol_references(symbol);
CREATE INDEX idx_refs_qualifier ON symbol_references(qualifier);

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

-- Full-text search (manually synced inside the index-files transaction)
CREATE VIRTUAL TABLE code_index_fts USING fts5(
  file_id UNINDEXED,
  path,
  name,
  summary,
  tags,
  symbol_names,
  symbol_summaries,
  reference_symbols
);
```

Notes:

- **`symbols` merges v1's `exports` and `variables` tables** — a variable is just `kind='variable'`. v1's naming was acknowledged as misleading; v2 fixes it.
- **`symbol_references` replaces `external_symbol_usages`.** Without the Dart analyzer there is no resolved dot-path; the language-neutral model is `symbol` + `qualifier` (the import string the agent attributes the symbol to) + `count`. Searches by bare symbol name still work; per-package precision is best-effort. The table is named `symbol_references` because `references` is an SQL keyword.
- **Symbol kind vocabulary** (agent must choose from): `class`, `interface`, `mixin`, `enum`, `function`, `method`, `constructor`, `getter`, `setter`, `variable`, `constant`, `typedef`, `extension`, `key` (config entries), `section` (markdown/doc headings), `other`.
- **Line-range sanity check:** on write, the MCP clamps/flags `line`/`end_line` values that exceed the file's `line_count` (sets them to NULL and records a warning in the response) so hallucinated ranges never poison partial reads.

---

## 7. Operation Surface

Single MCP tool `code-index`, multiplexed by `operation`, `project_dir` required on every call (consistent with `filesystem`, `git`, `planner`). 14 operations:

| Op | Kind | Purpose |
|----|------|---------|
| `scan` | scan | Walk tree, detect added/changed/deleted, return indexing plan |
| `index-files` | write | Batched write of agent-produced records (1..N files) |
| `get-file` | read | One file, selected layers |
| `get-files` | read | Batched `get-file` |
| `overview` | read | Compact listing: path + summary + tags + public symbol names |
| `search` | search | FTS5 across names, paths, summaries, tags, symbols, references |
| `find-symbol` | search | Symbol lookup → path + line range (the "jump to definition" op) |
| `references` | search | Which files use symbol X |
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
  "added": ["lib/new.dart"],
  "changed": ["lib/touched.dart"],
  "deleted": ["lib/gone.dart"],
  "unchanged_count": 214,
  "skipped_by_since": 0,
  "out_of_scope": ["scripts/build.sh"],
  "plan": [
    { "path": "lib/new.dart", "needs": [1, 2, 3] },
    { "path": "lib/touched.dart", "needs": [1, 2, 3] }
  ],
  "summary": { "files_to_index": 2, "estimated_batches": 1 }
}
```

`plan[].needs` lists the **agent-produced** layers wanted (0 is always computed by the MCP on write). The parent hands the whole response to `code-index-agent`. This operation is the v2 home of the v1 `auto-scan` + `diff` pair — one op instead of two; the `changed`/`added`/`deleted` arrays satisfy the "list changed files" requirement directly.

### 7.2 `index-files`

The single write path. Parameters: `files` — an array of 1..N records:

```json
{
  "files": [
    {
      "path": "lib/src/auth/session.dart",
      "language": "dart",
      "summary": "Manages login sessions: creation, refresh and expiry.",
      "tags": ["auth", "session", "login", "token", "expiry", "refresh"],
      "symbols": [
        { "name": "SessionManager", "kind": "class", "visibility": "public",
          "line": 14, "end_line": 182,
          "summary": "Owns the active session lifecycle." },
        { "name": "refresh", "kind": "method", "parent": "SessionManager",
          "visibility": "public",
          "signature": "(Duration ttl) -> Future<Session>",
          "line": 57, "end_line": 74,
          "summary": "Extends the session or throws SessionExpired." },
        { "name": "_store", "kind": "variable", "parent": "SessionManager",
          "visibility": "private", "line": 16 }
      ],
      "imports": ["package:http/http.dart", "lib/src/auth/token_store.dart"],
      "references": [
        { "symbol": "Client", "qualifier": "package:http/http.dart", "count": 2 }
      ],
      "annotations": [
        { "kind": "TODO", "message": "handle clock skew", "line": 61 }
      ]
    }
  ]
}
```

Per record, the MCP: validates the path (exists, allowed), computes layer 0 (stat, SHA-256, line/word counts), derives `layers_present`, sanity-checks line ranges, then upserts `files` + child tables + FTS row in one transaction per file. Only `path` is required — a record with just `path` still (re)freshes layer 0.

Response:

```json
{
  "indexed": ["lib/src/auth/session.dart"],
  "failed": [{ "path": "lib/broken.dart", "error": "File not found" }],
  "warnings": [{ "path": "lib/x.dart", "warning": "end_line 300 > line_count 244; range cleared for symbol 'foo'" }],
  "summary": { "indexed": 1, "failed": 1 }
}
```

Batching (5–10 files per call) replaces v1's one `auto-index` call per file — fewer round trips, and each file still commits independently so one bad record cannot poison a batch.

### 7.3 `get-file` / `get-files`

Parameters: `path` (or `paths`), `layers` (default `[0, 1, 4]`). Layer semantics per §5; requesting layer 2 or 3 returns symbols (with line ranges), imports, references, annotations; layer 4 filters symbols/references to `visibility='public'`. Response carries `needs_reindex` (§4.3).

### 7.4 `overview`

Parameters: `path_pattern`, `file_type`, `language`, `limit`. Returns, per file: `path`, `summary`, `tags`, `line_count`, and public symbol names — the cheapest way to orient in an unfamiliar area of the codebase.

### 7.5 `search`

Parameters: `query` (FTS5 match across all FTS columns; tokens are OR-joined with prefix matching, BM25 ranked — v1 semantics kept), plus AND-filters: `file_type`, `language`, `path_pattern`, `tag` (exact tag match), `symbol_name`, `symbol_kind`, `import_pattern`, `limit` (default 25). Returns compact hits: `path`, `summary`, `tags`, matched public symbols. Falls back to LIKE search if the FTS query is malformed (v1 behavior kept).

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

This is the new headline operation: symbol → exact file + line range → `filesystem read-file startLine=57 endLine=74`. A consumer answers "how does refresh work?" for ~20 source lines instead of a whole file.

### 7.7 `references`

Parameters: `symbol` (exact), `qualifier_pattern` (LIKE), `path_pattern`, `limit`. Returns `[{path, symbol, qualifier, count}]` ordered by count. Best-effort by design (§6 notes).

### 7.8 `dependents` / `dependencies`

Unchanged in spirit from v1. `dependents(path)` matches `imports.import_path` by suffix/normalized comparison and returns importing files. `dependencies(path)` returns the file's imports classified `internal` (resolves to an indexed file) or `external`.

### 7.9 `annotations`

Parameters: `kind`, `message_pattern`, `path_pattern`, `file_type`, `limit`. Returns entries with `by_kind` counts.

### 7.10 `stats`

Aggregates: files by language and type, symbols by kind, top imports, annotations by kind, **top 20 tags** (the tag cloud doubles as a vocabulary hint for `search`), freshness (`fresh`/`stale`/`pending`/`failed` counts), total line/word counts, db file size. No hash checks (counts only).

### 7.11 `project-info`

Returns: canonical project path, data directory, db path, `registry.json` entry, schema version, row counts, `last_scan_at`. Primarily for debugging and for the skill to verify the index exists before advising a full scan.

### 7.12 `is-allowed`

Unchanged from v1: checks a path against the `code-index` allowed paths from `jhsware-code.yaml`.

---

## 8. Search Design

### 8.1 FTS5 baseline

FTS5 with OR-joined prefix tokens and BM25 ranking carries over from v1 — it proved adequate for keyword search. The FTS row per file concatenates: path, name, summary, tags, symbol names, symbol summaries, and reference symbol names.

### 8.2 Semantic tags

The concept-search gap identified in `vector-search-research.md` ("auth" should find "login") is closed the lightweight way: the indexing agent emits **5–10 lowercase concept keywords** per file while it is already reading the file for summarization — near-zero marginal cost. Guidance for tag quality lives in the agent contract (`design-v2-agent-and-skill.md`); in short: domain concepts, synonyms of the file's terminology, architectural role (`repository`, `http-client`, `migration`), not restatements of the filename.

Tags are stored as a JSON array on `files.tags` and flattened into the `tags` FTS column. `search` matches them via the general `query` and via the exact `tag` filter; `stats` exposes the top-tag cloud so consumers can discover the vocabulary.

### 8.3 Embeddings — explicitly out of scope

Per the standing recommendation in `vector-search-research.md`: no vector search. The Dart CLI embedding ecosystem is immature, external embedding APIs add key-management friction, and tags + FTS5 cover the realistic gap. Revisit only if tag-based search demonstrably falls short.

### 8.4 Precision trade-off from dropping the analyzer

v1's resolved dot-paths (`flutter.material.Widget`) enabled exact "which files use Widget *from material*" queries. v2's agent-extracted `symbol_references` keeps the common query ("which files use `Widget`") and approximates the qualified query via `qualifier_pattern`. This is a deliberate trade: less precision on one query family, in exchange for a dramatically simpler MCP (no analyzer dependency, no multi-second context builds, ~30MB smaller binary), uniform behavior across languages, and an index whose quality is the same for Dart, TypeScript, Python, YAML, or Markdown.

---

## 9. Roles

| Component | Role | Contract |
|-----------|------|----------|
| `code_index` MCP | Durable store + query engine. Computes layer 0. Never parses source, never calls an LLM. | This document |
| `code-index-agent` (Haiku) | Disposable worker. Reads files via `filesystem`, produces layers 1–3 records, writes via `index-files`. | `design-v2-agent-and-skill.md` §Agent |
| `code-index` skill | Consumer-side query guide for parent agents: cheap-first querying, the find-symbol → partial-read pattern, needs_reindex policy, when to spawn the agent. | `design-v2-agent-and-skill.md` §Skill |

The v1 execution model is kept: **pull-based** (Model A). The parent runs `scan`, hands the plan to the agent, the agent writes back through `index-files`. The MCP never spawns anything.

---

## 10. End-to-End Flows

### 10.1 Session start

```
parent → code-index: scan
         ← { added: [...], changed: [...], plan: [...(12 files)...] }
parent → spawn code-index-agent with the scan response
         (agent: read-files in batches of 5–10 → index-files per batch)
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

### 10.3 Read against a changed file

```
parent → code-index: get-file path="lib/foo.dart"
         ← { ...stored layers..., needs_reindex: [{ path: "lib/foo.dart", reason: "changed" }] }
parent → (freshness matters?) spawn code-index-agent with the needs_reindex batch
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
| Indexing tokens | ~1 Haiku completion per 5–10-file batch (read + extract). Only added/changed files are ever re-indexed. |
| Index size | ~2–5 KB of row data per file; a 1k-file project ≈ a few MB. |
| Binary/startup | No `analyzer` dependency: smaller compile, no per-scan analysis-context build (v1 paid seconds per scan for resolved analysis). |
| Concurrency | WAL + busy_timeout=5000 (multiple MCP server processes may share a project DB safely; single-writer per transaction). |

---

## 13. Migration from v1

Clean break, no data migration:

1. v1 databases under `[planner-data-root]/projects/*/db/code_index.db` are simply abandoned in place (they are disposable caches). They can be deleted manually by the user whenever convenient — the tool never deletes them.
2. First `scan` against a project creates `~/.code-index/<basename>-<hash8>/`, registers it in `registry.json`, and reports every file as `added`.
3. One full agent indexing pass rebuilds the index. Cost: one Haiku batch call per 5–10 files, once.
4. Operation renames for consumers: `auto-scan`+`diff` → `scan`; `auto-index` → `index-files`; `usages` → `references`; `search-annotations` → `annotations`; `overview`/`get-file`/`get-files`/`search`/`dependents`/`dependencies`/`stats`/`is-allowed` keep their names. The skill and agent are rewritten in the same change, so no consumer sees a mixed vocabulary.

---

## 14. Testing Strategy

- **Unit:** hash utils (sha256 + short-circuit logic), registry/meta read-modify-write + atomic rename, schema create/rebuild, per-operation handlers (validation, allowed-paths, layer filtering, FTS sync, line-range clamping).
- **Fixtures:** extend `test/fixtures/sample_project` with non-Dart files (yaml, md, js) since v2 treats every language identically.
- **Integration:** the §10 flows end-to-end against a temp `--data-root`; collision test (two projects with the same basename get distinct directories); registry rebuild after deletion; stale-on-read after touching a fixture file; `rebuild: true` round trip.
- **Concurrency smoke test:** two connections writing/reading under WAL.

---

## 15. Implementation Plan

1. **Storage foundation** — data-root resolution, `<basename>-<hash8>` derivation, `registry.json` + `meta.json` with atomic writes, SHA-256 hash utils with mtime+size short-circuit, clean-rebuild schema v2. Drop `xxh3`/`analyzer`/`uuid`-where-unneeded from `pubspec.yaml`, add `crypto`.
2. **Write path** — `index-files`: record validation, layer-0 computation, `layers_present` derivation, line-range sanity checks, transactional upsert + FTS sync.
3. **Scan** — walk + short-circuit diff + plan (`since`, `rebuild`, `remove_deleted`, `verify`, `extensions`).
4. **Read path** — `get-file`/`get-files` (layers), `overview`, `project-info`, stale detection (`needs_reindex`).
5. **Search family** — `search` (FTS + filters + LIKE fallback), `find-symbol`, `references`, `dependents`, `dependencies`, `annotations`, `stats`.
6. **MCP wiring** — tool registration/schema, `--data-root` argument, help text, remove `--planner-data-root`.
7. **Tests** — per §14.
8. **Agent rewrite** — `agentic-plugins/jhsware-code/agents/code-index-agent.md` per the v2 contract.
9. **Skill rewrite** — `agentic-plugins/jhsware-code/skills/code-index/SKILL.md` per the v2 contract.
10. **Docs** — package README, CHANGELOG; keep this document in sync with as-built decisions.

---

## 16. Open Questions

- **Tag vocabulary drift.** Different Haiku versions may tag differently over time; mixed vocabularies degrade tag search slightly. Default position: acceptable (tags are additive to FTS keywords); revisit a `reindex-tags` maintenance flow only if observed in practice.
- **`registry.json` concurrent writers.** Two server processes starting simultaneously could race the registry write. Atomic rename makes the loser's write win harmlessly (both entries are deterministic and identical in content except timestamps). A lock file is deliberately omitted until a real problem appears.
- **Symbol cap.** Very large generated files could produce thousands of symbols. Proposed default: agent caps at 150 symbols/file and sets a `truncated: true` marker in the record; MCP stores it on `files.analysis_error` as an informational note. To be validated during implementation.
