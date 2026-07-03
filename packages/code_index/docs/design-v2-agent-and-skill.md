# Code Index v2 — Agent & Skill Contracts

**Status:** Approved design — implementation not started
**Date:** 2026-07-03
**Author:** sebastian@urbantalk.se
**Parent design:** `design-v2-architecture.md`

This document specifies the two LLM-side artifacts that ship with the v2 rewrite:

- `agentic-plugins/jhsware-code/agents/code-index-agent.md` — the **writer**: a Haiku worker that reads source via `filesystem` and populates the index via `code-index index-files`.
- `agentic-plugins/jhsware-code/skills/code-index/SKILL.md` — the **reader's guide**: teaches parent agents how to query the index token-efficiently.

The hard rule carried over from v1: the skill is consumer-side only, the indexing playbook lives in the agent. Neither document duplicates the other.

---

## Part 1 — `code-index-agent` (writer)

### 1.1 Frontmatter (unchanged shape)

```yaml
name: code-index-agent
description: Index code files for quick and token efficient exploration and search in code base.
tools: filesystem, code-index
disallowed-tools: Bash, Read, Write, Edit, Cowork
permission-mode: dontAsk
model: haiku
```

### 1.2 Contract

The parent drives indexing (pull model). The agent never calls `scan` itself. It accepts one of two inputs:

**Input A — a `scan` response** (or at minimum its `plan` array):

```json
{
  "plan": [{ "path": "lib/src/foo.dart", "needs": [1, 2, 3] }],
  "out_of_scope": ["vendor/lib.js"]
}
```

**Input B — a `needs_reindex` array** from any read response:

```json
{ "needs_reindex": [{ "path": "lib/src/bar.dart", "reason": "changed" }] }
```

Input B entries are treated as plan items with `needs: [1, 2, 3]`.

`needs` refers to agent-produced layers only (1 = summary+tags, 2 = structure, 3 = symbol summaries). Layer 0 is always computed by the MCP on write.

### 1.3 Workflow

1. **Normalize** both input shapes into one list of `{ path, needs }`.
2. **Batch** 5–10 files. Group similar languages together when convenient.
3. Per batch:
   a. `filesystem read-files` with comma-separated paths. The output is line-numbered (`L1:`, `L2:` …) — **these numbers are the source of truth for `line` / `end_line`**.
   b. Build one record per file (see 1.4).
   c. Submit the whole batch in **one** `code-index index-files` call.
4. **Report** (see 1.6).

The v1 flow of one `auto-index` call per file is gone; one call per batch.

### 1.4 Record extraction spec

Produce only the layers listed in `needs`; `path` is always included.

| Field | Layer | Rules |
|-------|:-----:|-------|
| `language` | — | Lowercase language name (`dart`, `typescript`, `yaml`, `markdown`, …). Omit if unsure — the MCP falls back to an extension map. |
| `summary` | 1 | One sentence, ≤ 25 words, present tense, states what the file *provides* — not how it is written. Use the codebase's domain vocabulary so FTS finds it. |
| `tags` | 1 | 5–10 lowercase keywords. Cover: (a) domain concepts (`auth`, `session`), (b) **synonyms** of the file's own terminology (`login` for `signIn`), (c) architectural role (`repository`, `http-client`, `migration`, `widget`). Never restate the filename or path. |
| `symbols` | 2 | Every top-level declaration and every class/struct member. Fields: `name`, `kind` (from the vocabulary in the parent design §6), `visibility` (`public`/`private` by the conventions of the language — `_` prefix in Dart, `#`/non-exported in JS/TS, `_` in Python), `parent` (enclosing symbol), `signature` (compact, e.g. `(Duration ttl) -> Future<Session>`; omit for variables), `line`, `end_line` (from the read-file line numbers; `end_line` = last line of the declaration body). Cap at 150 symbols per file and note truncation in the report. |
| `imports` | 2 | Import/require/include paths verbatim, one entry per statement. |
| `references` | 2 | External symbols this file actually *uses* (not merely imports): `{ symbol, qualifier, count }` where `qualifier` is the import path you attribute the symbol to. Only the meaningful ones — cap 20, ordered by importance. Best-effort; skip for config/doc files. |
| `annotations` | 2 | `TODO`/`FIXME`/`HACK`/`NOTE`/`DEPRECATED` comments: `{ kind, message, line }`. |
| `symbols[].summary` | 3 | One sentence per **public** symbol. Skip private symbols and trivial getters/setters. |

Non-code files:

- **Config** (yaml, json, toml): top-level keys as symbols with `kind: "key"`; summary describes what the file configures.
- **Markdown/docs:** headings as symbols with `kind: "section"` and their line ranges; tags describe the topics covered.

### 1.5 Quality rules

- Never invent symbols, line numbers, or references — extract only what is visible in the read output.
- Line numbers must come from the `L<n>:` prefixes; the MCP clamps out-of-range values and reports a warning, which counts against the file's quality.
- If a file is unreadable or binary, skip it and list it under `failed`.
- Do not read or index `out_of_scope` paths; echo them in the report.
- On `index-files` failure for a batch: retry once; then add the batch's files to `failed` and continue.

### 1.6 Final report

```json
{
  "indexed": 42,
  "failed": [{ "path": "lib/broken.dart", "error": "read error" }],
  "truncated": ["lib/generated/api.dart"],
  "out_of_scope": ["vendor/lib.js"]
}
```

---

## Part 2 — `code-index` skill (reader's guide)

### 2.1 Frontmatter (unchanged shape)

```yaml
name: code-index
description: Query the layered code index for token-efficient codebase exploration and search.
allowed-tools: filesystem, code-index
model: haiku
context: fork
agent: code-index-agent
```

### 2.2 Core teaching: cheap before expensive

The layer table (§5 of the parent design) with token costs, and the rule: start with `overview`/`search`, request layer 2/3 only when needed, read raw source only as the last step — and then only the line range you need.

### 2.3 Query patterns

The skill documents these named patterns — this is the "useful search patterns" catalog the whole v2 design serves:

**P1 — Orient** (unfamiliar area):

```
code-index: overview path_pattern="lib/auth"
→ path + summary + tags + public symbols per file, ~40 tokens each
```

**P2 — Concept search** (you know the *idea*, not the identifier):

```
code-index: search query="session expiry refresh"
→ semantic tags make "auth"-style vocabulary work even when the code says "signIn"
→ if a search misses: retry with synonyms, or check stats' top-tags for the index vocabulary
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
code-index: dependents path="lib/src/auth/session.dart"   # who imports it
code-index: references symbol="SessionManager"            # who uses the symbol
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

### 2.4 Freshness policy

- Every read may return `needs_reindex: [{ path, reason }]`. Decision rule (kept from v1): if correctness matters for the current question, spawn `code-index-agent` with the batch; otherwise continue — stale summaries are usually close enough.
- **Session start:** run `code-index: scan` and, if the plan is non-empty, hand the response to `code-index-agent` before heavy querying.
- **Routine reads never spawn the agent.**

### 2.5 Boundaries

- `out_of_scope` responses are normal: the index will not answer about that path — fall back to `filesystem read-file`.
- `project-info` tells you whether an index exists at all (fresh checkout → run the scan flow first).
- Every call requires `project_dir`.

---

## Part 3 — Division of labor (summary)

| Question | Answered by |
|----------|-------------|
| "What does this file/area do?" | skill: P1/P2 (index reads) |
| "Where is symbol X and what does it look like?" | skill: P3 (`find-symbol` + partial read) |
| "Who uses/imports X?" | skill: P4 (`references`/`dependents`) |
| "Index is stale/missing — fix it" | agent, driven by `scan` plan or `needs_reindex` batch |
| "Parse this file into the index" | agent only — consumers never call `index-files` |
