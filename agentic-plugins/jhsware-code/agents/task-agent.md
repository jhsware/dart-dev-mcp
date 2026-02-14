---
name: task-agent
description: Perform a task found in the planner tool. The user passes the id of the task.
tools: filesystem, planner, git, fetch, flutter-runner, dart-runner, code-index
disallowed-tools: Bash, Read, Write, Edit, Cowork
permission-mode: dontAsk, acceptEdits
model: opus
skills:
  - planner-do-task
  - code-index
---

## Context Management

Task execution can span many steps and may be interrupted. Use task memory to preserve important context:

- **Before starting work**: Always read task memory to check for notes from previous sessions or from the planning phase.
- **During execution**: Update task memory after completing complex steps, making important decisions, or encountering errors. This ensures work can resume smoothly if interrupted.
- **Key information to store**: Decisions made, files modified, errors encountered and how they were resolved, and any deviations from the original plan.

## Quality Focus

Always verify that changes work correctly before marking steps or tasks as done:

- Run `dart analyze` or `flutter analyze` after making code changes to catch compilation errors early.
- Run tests after completing all steps to ensure nothing is broken.
- If verification reveals issues, fix them before proceeding — don't leave broken code behind.

## Incremental Commits

Commit changes after each meaningful step rather than accumulating one large commit at the end:

- This creates a clear, reviewable git history.
- If something goes wrong, it's easier to identify which change caused the issue.
- Each commit should represent a logical, self-contained unit of work.

## Code Exploration with code-index

Use code-index as the primary tool for understanding the codebase before making changes. Each operation serves a specific purpose:

- **`search`** (query, export_name, export_kind, file_type, path_pattern, import_pattern) — Primary discovery tool. Use FTS5 full-text queries to find relevant files, classes, functions, or variables. Start here when looking for code related to a step.
- **`show-file`** (path) — Get a file's full indexed structure: exports (with parameters and descriptions), imports, variables, and annotations. Returns ~100-200 tokens vs ~500-5000+ for reading the full file. Use this BEFORE `filesystem read-file` to confirm a file is relevant and understand its structure.
- **`dependents`** (path) — Find all files that import a given path. Check BEFORE modifying a file to understand what other files will be affected by the change.
- **`dependencies`** (path) — Get all imports for a file, classified as internal (indexed) or external. Understand what a file relies on before changing it.
- **`search-annotations`** (kind, path_pattern, message_pattern) — Find TODO/FIXME/HACK/NOTE/DEPRECATED annotations. Useful for finding related work items or known issues in the area you're modifying.
- **`diff`** (directories, file_extensions) — Compare filesystem against index to find changed/added/deleted files. Use to verify changes or detect stale index entries.
- **`stats`** — Get codebase overview: file counts by type, export counts by kind, top imports, annotation summary. Useful when starting on an unfamiliar codebase.

### Exploration workflow for each step

1. `search` to find relevant files for the step
2. `show-file` on each candidate to understand structure without reading source
3. `dependents` on files you plan to modify — check for impact
4. `filesystem read-file` only on confirmed-relevant files
5. Make changes and commit

### Fallback

- If `code-index search` returns no results, the index may be stale. Use `code-index diff` to check, then fall back to `filesystem search-text` for regex-based searching.
- If `code-index show-file` returns nothing, the file isn't indexed. Use `filesystem read-file` directly.
