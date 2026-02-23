---
name: planner-do-task
description: Perform a task found in the planner tool. The user passes the id of the task.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
context: fork
agent: task-agent
---

ultrathink

## Phase 1 — Setup

1. **Read project instructions**: Call `planner` with operation `get-project-instructions` to understand project conventions and constraints.
2. **Fetch the task**: Call `planner` with operation `show-task` using the task id provided by the user. Examine the title, details, and steps.
3. **Check task memory**: Call `planner` with operation `show-task-memory` to see if there are notes from previous work or planning. If the task was partially completed before, this tells you where to resume.
4. **Determine task type**:
   - **Regular task**: Title does NOT start with "Parent:". Has steps that describe work to perform directly.
   - **Parent task**: Title starts with "Parent:". Steps reference sub-tasks via `sub_task_id`.
5. **Update task status**: Change task status to `started`.
6. **Create git branch** (skip for parent tasks): If the task involves file edits, create a branch using `git branch-create` with the pattern `task/<short-task-description>` and switch to it with `git branch-switch`.

### Resuming a partially completed task

If some steps already have status `done`:
- Skip completed steps — do NOT re-do them
- Start from the first step with status `todo`
- Read task memory for context on what was already accomplished
- Check if a git branch already exists for this task

## Phase 2 — Execution

Process each step in order:

### For parent tasks

A task is a parent task when its title starts with "Parent:". Parent task steps reference sub-tasks via `sub_task_id`. For each parent task step:
1. Change step status to `started`
2. Call `planner` with operation `get-subtask-prompt` using the step's id
3. This returns the sub-task's full details (title, description, steps)
4. Invoke `/planner-do-task` skill with the sub-task id
5. After the sub-task completes, change step status to `done`

**IMPORTANT**: Use `get-subtask-prompt` (not `show-task`) to fetch sub-task details. This operation is specifically designed to retrieve the sub-task linked to a parent task step. This operation is specifically designed to retrieve the sub-task linked to a parent task step, and will return an error if the step has no linked sub-task.
**IMPORTANT**: Do not perform any work on the parent task, it is an orchestration task that makes sure we perform the sub-tasks in the correct order.

### For regular tasks

For each step:
1. Change step status to `started`
2. **Read step details**: Call `planner` with operation `show-step` using the step's id to get the full detailed instructions. Read these carefully — they describe exactly what to change, which files to modify, and what the expected outcome is. Follow these instructions precisely.
3. **Ensure index is fresh** (once per task, not per step) — Run `code-index diff` (optionally filtering to relevant directories) at the start of a task. If there are changed or added files, spawn a code-index-agent to re-index them before exploring.
4. **Explore before editing** — Use code-index to understand context before making changes:
   - `code-index overview` — Get a compact listing of all indexed files with descriptions and exports. Use at the start to understand the codebase layout (~50-100 tokens).
   - `code-index search` — find files related to the step's work. Supports FTS5 queries with filters: `query`, `export_name`, `export_kind`, `file_type`, `path_pattern`, `import_pattern`.
     > **Note:** `search` is keyword-based (FTS5). It works well for individual words and prefix matches but does NOT support phrase search. Multi-word queries are treated as independent keywords. For phrase or regex matching, use `filesystem search-text`.
   - `code-index file-summary` (path) — get a file's exports grouped by class, with descriptions and parameters. Lighter than `show-file` — use when you only need to understand what a file provides (no imports/annotations/timestamps).
   - `code-index show-file` (path) — understand a file's full structure (exports, imports, variables, annotations) without reading full source. Returns ~100-200 tokens vs ~500-5000+ for `filesystem read-file`. Use when you need imports and annotations.
   - `code-index dependents` (path) — find all files that import a given path. Check this BEFORE modifying a file to understand impact on other files.
   - `code-index dependencies` (path) — get all imports for a file, classified as internal or external. Understand what a file relies on before changing it.
   - `code-index search-annotations` — find TODO/FIXME/HACK/NOTE/DEPRECATED annotations. Filter by `kind`, `path_pattern`, `message_pattern`, `file_type`.
5. **Read and edit files**:
   - `filesystem read-file` — read specific files after confirming relevance with show-file
   - `filesystem edit-file` — modify files (use startLine/endLine for targeted edits, or omit to overwrite)
   - `filesystem create-file` — create new files
   - `filesystem search-text` — regex-based search as fallback when code-index search isn't sufficient
6. After completing the step work, commit changes to git (see Git Workflow below)
7. Change step status to `done`
8. Update task memory with a brief note about what was accomplished

### Ensuring code-index is available

If `code-index search` returns no results for queries you expect to match:
- The index may be stale or empty. Use `code-index diff` with the relevant directories to check.
- Fall back to `filesystem search-text` for the current step.
- Note in task memory that the index needs updating.

## Phase 3 — Verification (skip for parent tasks)

After all steps are complete, verify the work:

1. **Run analysis**: Use `dart-runner` with operation `analyze` or `flutter-runner` with operation `analyze` to check for compilation errors and warnings.
2. **Run tests**: If the project has tests, use `dart-runner` with operation `test` or `flutter-runner` with operation `test`.
3. **If errors are found**:
   - Fix the errors
   - Re-run analysis/tests to confirm the fix
   - Commit the fix to git
   - Update task memory noting what was fixed

## Phase 4 — Completion

1. **Merge git branch** (skip for parent tasks): Switch to master with `git branch-switch`, then merge the task branch with `git merge`.
2. **Update task status**:
   - If git branch was merged: set status to `merged`
   - If parent task or no git branch: set status to `done`
3. **Update task memory**: Write a brief summary of what was accomplished, any decisions made, and any follow-up work identified.

## Git Workflow

### Branch naming

Use the pattern: `task/<short-description>`
- Example: `task/add-input-validation`
- Example: `task/fix-auth-token-refresh`
- Keep it short, lowercase, hyphen-separated

### When to commit

- **After each step** that modifies files — this creates a clear history
- **After fixing errors** found during verification
- Each commit should be a logical unit of work

### Commit message format

Write descriptive commit messages that explain what was changed and why:
- First line: concise summary (imperative mood)
- If needed, add a blank line followed by more detail
- Example: `Add email validation to registration form`
- Example: `Fix JWT token refresh to handle expired tokens gracefully`

## Task Memory

Task memory preserves context across steps and across interrupted sessions. Use `planner` with operation `update-task-memory`.

### What to store

- Decisions made during execution (e.g., "chose approach X over Y because...")
- Problems encountered and how they were resolved
- Files modified or created
- Summary of progress after each significant milestone

### When to update

- After making an important decision
- After encountering and resolving an error
- After completing a complex step
- At the end of the task (final summary)

## Error Handling

- **Code doesn't compile**: Read the error messages carefully. Fix the issues, re-run analysis. If stuck, update task memory with the error and ask the user for guidance.
- **Tests fail**: Check if the failure is related to your changes or pre-existing. Fix test failures caused by your changes. If pre-existing, note in task memory and continue.
- **File not found**: Verify the path using `filesystem list-content`. The file may have been moved or renamed. Check git history with `git log` if needed.
- **Git merge conflicts**: If merging to master fails due to conflicts, note the conflict in task memory and ask the user for guidance. Do not force-resolve conflicts without understanding the other changes.
- **Step is unclear**: If a step's details are insufficient to complete the work, check task memory and task details for additional context. If still unclear, ask the user for clarification.
- **code-index returns no results**: Index may be stale. Use `code-index diff` to check, then fall back to `filesystem search-text`. Note in task memory.
- **code-index show-file returns nothing for a known file**: File is not indexed. Use `filesystem read-file` directly for that file.

## Examples

### Example 1 — Regular task execution with code-index exploration

```
# Phase 1 — Setup
planner: get-project-instructions
planner: show-task (id: "abc-123")
planner: show-task-memory (id: "abc-123")
git: branch-create (branch: "task/add-validation")
git: branch-switch (branch: "task/add-validation")
planner: update-task (id: "abc-123", status: "started")

# Phase 2 — First ensure index is fresh (once per task)
code-index: diff (file_extensions: [".dart", ".tsx"])
# → 0 changed, 0 added — index is fresh

# Get overview to understand codebase layout
code-index: overview (path_pattern: "src/components%")
# → 5 component files listed with descriptions and exports

# Phase 2 — Execution (step 1: understand context first)
planner: update-step (id: "step-1", status: "started")
planner: show-step (id: "step-1")
# → Read the step's detailed instructions: what to change, which files, expected outcome

# Search for specific files related to this step
code-index: search (query: "Form", export_kind: "class")
# → Found Form class in src/components/Form.tsx

# Understand file API surface
code-index: file-summary (path: "src/components/Form.tsx")
# → exports grouped by Form: { build, _onSubmit, _validate }

code-index: dependents (path: "src/components/Form.tsx")
# → 2 files import this: App.tsx, FormPage.tsx

code-index: dependencies (path: "src/components/Form.tsx")
# → internal: src/utils/validation.ts (indexed), external: react

# Now read the specific file to make changes
filesystem: read-file (path: "src/components/Form.tsx")
filesystem: edit-file (path: "src/components/Form.tsx", content: "...", startLine: 10, endLine: 25)
git: add (files: ["src/components/Form.tsx"])
git: commit (message: "Add email validation to Form component")
planner: update-step (id: "step-1", status: "done")
planner: update-task-memory (id: "abc-123", memory: "Step 1 done: updated Form.tsx with validation. 2 dependents: App.tsx, FormPage.tsx — no changes needed there.")

# Phase 2 — Execution (step 2)
planner: update-step (id: "step-2", status: "started")
planner: show-step (id: "step-2")
# → Read the step's detailed instructions
filesystem: create-file (path: "src/utils/validation.ts", content: "...")
git: add (files: ["src/utils/validation.ts"])
git: commit (message: "Add validation utility functions")
planner: update-step (id: "step-2", status: "done")

# Phase 3 — Verification
dart-runner: analyze
dart-runner: test

# Phase 4 — Completion
git: branch-switch (branch: "master")
git: merge (branch: "task/add-validation")
planner: update-task (id: "abc-123", status: "merged")
planner: update-task-memory (id: "abc-123", memory: "Completed: added email validation...")
```

### Example 2 — Parent task execution flow

```
# Phase 1 — Setup
planner: get-project-instructions
planner: show-task (id: "parent-456")
planner: show-task-memory (id: "parent-456")
# No git branch for parent tasks
planner: update-task (id: "parent-456", status: "started")

# Phase 2 — Execution (step 1, references sub-task)
planner: update-step (id: "step-1", status: "started")
planner: get-subtask-prompt (id: "step-1")
# → Returns sub-task details for "sub-task-789"
# Invoke /planner-do-task skill with sub-task id "sub-task-789"
planner: update-step (id: "step-1", status: "done")

# Phase 2 — Execution (step 2, references another sub-task)
planner: update-step (id: "step-2", status: "started")
planner: get-subtask-prompt (id: "step-2")
# → Returns sub-task details for "sub-task-012"
# Invoke /planner-do-task skill with sub-task id "sub-task-012"
planner: update-step (id: "step-2", status: "done")

# Phase 4 — Completion (no verification or merge for parent tasks)
planner: update-task (id: "parent-456", status: "done")
planner: update-task-memory (id: "parent-456", memory: "Both sub-tasks completed successfully.")
```

### Example 3 — Error recovery

```
# After completing all steps, run verification
dart-runner: analyze
# → Returns errors: "Type 'String' is not assignable to type 'int' at line 42"

# Fix the error
filesystem: read-file (path: "./src/utils/calc.dart")
filesystem: edit-file (path: "./src/utils/calc.dart", content: "...", startLine: 42, endLine: 42)

# Re-verify
dart-runner: analyze
# → No errors

# Commit the fix
git: add (files: ["./src/utils/calc.dart"])
git: commit (message: "Fix type error in calc utility")

# Update memory with what happened
planner: update-task-memory (id: "abc-123", memory: "...Fixed type error in calc.dart line 42...")
```

## Tool Reference

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project.

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.
