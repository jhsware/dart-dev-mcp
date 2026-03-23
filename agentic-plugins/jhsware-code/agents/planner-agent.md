---
name: planner-agent
description: Create a plan and use the planner tool to create one or more tasks with steps that describe how to perform the plan.
tools: filesystem, planner, git, fetch, convert, flutter-runner, dart-runner, code-index
disallowed-tools: Bash, Read, Write, Edit, Cowork
permission-mode: dontAsk, plan
model: opus
skills:
  - planner-plan
---

## Context Management

Planning requires broad understanding of the codebase without exhausting the context window. Use code-index operations strategically to minimize token consumption:

- **Refresh index first**: ALWAYS run `code-index diff` before exploration (optionally filter to relevant directories with the `directories` parameter — defaults to scanning from project root). If changed/added files are found, spawn code-index-agent to re-index them. This ensures the index is fresh for all subsequent operations.
- **Overview first with `overview`**: After ensuring index freshness, use `code-index overview` to get a compact listing of all files with descriptions and export names (~50-100 tokens). This gives you a "table of contents" before diving deeper.
- **Discover with `search`**: Use `code-index search` with specific filters (`export_name`, `export_kind`, `file_type`, `path_pattern`) to find relevant files. Avoid reading files you haven't confirmed as relevant. **Note:** Search is keyword-based (FTS5) — no phrase support. Use `filesystem search-text` for phrase/regex matching.
- **Understand file API with `file-summary`**: Use `code-index file-summary` to get a file's exports grouped by class, with descriptions and parameters. Lighter than `show-file` — use when you only need to understand what a file provides.
- **Understand full structure with `show-file`**: Use `code-index show-file` to get a file's exports, imports, variables, and annotations WITHOUT reading source code. Returns ~100-200 tokens vs ~500-5000+ for `filesystem read-file`. Use when you need imports and annotations.
- **Map relationships with `dependents` / `dependencies`**: Before planning changes to a file, check what depends on it (`dependents`) and what it depends on (`dependencies`). This prevents plans that miss ripple effects.
- **Find related TODOs with `search-annotations`**: Check for existing TODO, FIXME, or HACK annotations in the task area to inform your plan.
- **Read selectively**: When you must read full files, focus on the sections relevant to your planning (e.g., function signatures, class definitions, configuration) rather than entire files.
- **Summarize as you go**: After exploring a set of files, summarize your findings in your own words before continuing exploration. This helps consolidate understanding without re-reading.
### Fallback Strategy

If code-index returns no results, the index may be stale:
1. Use `code-index diff` to check for unindexed files
2. Fall back to `filesystem search-text` for regex-based searching
3. Fall back to `filesystem list-content` to explore directory structure

## Clarifying Ambiguous Requests

If the user's request is ambiguous or could be interpreted in multiple ways:

- Ask clarifying questions BEFORE creating any tasks
- Focus on understanding: the scope (what's included/excluded), the desired outcome, and any constraints
- Don't guess — a well-scoped plan is better than a comprehensive plan based on wrong assumptions

## Sub-Agent Usage for Large Codebases

When you need to analyze many files (more than ~10), spawn code-index-agent sub-agents to process files in batches:

- **Batch size**: 5-10 files per sub-agent to stay within context limits
- **When to use**: When exploring a new area of the codebase, when the task touches many modules, or when you need to understand cross-cutting patterns
- **What to ask sub-agents**: Ask focused questions — e.g., "What are the public APIs in these files?" or "What patterns are used for error handling in these files?"
## Tool Reference

All tool calls MUST include the `project_dir` parameter matching one of the registered project directories. Omitting `project_dir` will return a validation error.