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

## Process Overview

The planner-do-task skill defines the full execution process. This agent doc reinforces the critical behaviors that must not be skipped.

**Phase 1 — Setup**: Read project instructions, fetch the task (show-task), check task memory, determine if it's a regular or parent task, update status to started, create a git branch (skip for parent tasks).

**Phase 2 — Execution**: Process each step in order. For regular tasks: read step details (show-step), explore, edit, commit. For parent tasks: use get-subtask-prompt to fetch the sub-task, then invoke the /planner-do-task skill with the sub-task id.

**Phase 3 — Verification** (skip for parent tasks): Run analyze and tests to verify changes work.

**Phase 4 — Completion**: Merge git branch to master (skip for parent tasks), update task status, write final task memory.


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

## Step Execution — CRITICAL

For EVERY step, before doing any work:

1. **Call `show-step`** with the step's id to read the full detailed instructions. Steps contain specific information about what to change, which files to modify, and expected outcomes.
2. **Follow the step instructions precisely** — make the specific targeted edits described in the step details. Do NOT rewrite entire files based on general understanding. If the step says "add a method to class X in file Y", edit that specific location.
3. **For parent task steps** (when the step has a `sub_task_id`): Call `get-subtask-prompt` with the step's id to fetch the linked sub-task. Then invoke the `/planner-do-task` skill with that sub-task's id. Do NOT try to do the sub-task's work directly — delegate it to a new skill invocation.

### Parent Task Detection

A task is a parent task when its title starts with "Parent:". Parent task steps reference sub-tasks via `sub_task_id`. For each parent task step:
1. Change step status to `started`
2. Call `planner` with operation `get-subtask-prompt` using the step's id
3. This returns the sub-task's full details (title, description, steps)
4. Invoke `/planner-do-task` skill with the sub-task id
5. After the sub-task completes, change step status to `done`

**IMPORTANT**: Use `get-subtask-prompt` (not `show-task`) to fetch sub-task details. This operation is specifically designed to retrieve the sub-task linked to a parent task step.

## Git Branch Workflow

For regular tasks (not parent tasks):
- **Create a branch** at the start: `git branch-create` with pattern `task/<short-description>`, then `git branch-switch`
- **Commit after each step** that modifies files — one commit per logical unit of work
- **Merge on completion**: Switch to master, merge the task branch, update task status to `merged`


## Code Exploration with code-index

Use code-index as the primary tool for understanding the codebase before making changes. Each operation serves a specific purpose:

- **`diff`** (directories, file_extensions) — ALWAYS run first (once per task) to ensure the index is up-to-date. Compare filesystem against index to find changed/added/deleted files. If changed/added files are found, spawn code-index-agent to re-index them before exploring.
- **`overview`** — Get a compact listing of all indexed files with path, description, file_type, and export names. Use as the first exploration step after ensuring index freshness to understand the codebase layout (~50-100 tokens).
- **`search`** (query, export_name, export_kind, file_type, path_pattern, import_pattern) — Primary discovery tool. Use FTS5 full-text queries to find relevant files, classes, functions, or variables. **Note:** Keyword-based (FTS5) — no phrase search. Multi-word queries match independent keywords. For phrase/regex, use `filesystem search-text`.
- **`file-summary`** (path) — Get a file's exports grouped by class, with descriptions and parameters. Lighter than `show-file` — use when you only need to understand what a file provides (no imports/annotations/timestamps).
- **`show-file`** (path) — Get a file's full indexed structure: exports (with parameters and descriptions), imports, variables, and annotations. Returns ~100-200 tokens vs ~500-5000+ for reading the full file. Use when you need imports and annotations.
- **`dependents`** (path) — Find all files that import a given path. Check BEFORE modifying a file to understand what other files will be affected by the change.
- **`dependencies`** (path) — Get all imports for a file, classified as internal (indexed) or external. Understand what a file relies on before changing it.
- **`search-annotations`** (kind, path_pattern, message_pattern) — Find TODO/FIXME/HACK/NOTE/DEPRECATED annotations. Useful for finding related work items or known issues in the area you're modifying.
- **`stats`** — Get codebase overview: file counts by type, export counts by kind, top imports, annotation summary. Useful for aggregate statistics.

### Exploration workflow for each step

0. `diff` + re-index (once per task, not per step)
1. `overview` to see all files and understand codebase layout
2. `search` to find relevant files for the step
3. `file-summary` or `show-file` on candidates to understand structure
4. `dependents` on files you plan to modify — check for impact
5. `filesystem read-file` only on confirmed-relevant files
6. Make changes and commit

### Fallback

- If `code-index search` returns no results, the index may be stale. Use `code-index diff` to check, then fall back to `filesystem search-text` for regex-based searching.
- If `code-index show-file` returns nothing, the file isn't indexed. Use `filesystem read-file` directly.
