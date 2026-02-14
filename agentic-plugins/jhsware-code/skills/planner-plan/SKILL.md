---
name: planner-plan
description: Create a plan and use the planner tool to create one or more tasks with steps that describe how to perform the plan.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
context: fork
agent: planner-agent
---

ultrathink

## Phase 1 — Setup

Before doing anything else:

1. **Read project instructions**: Call `planner` with operation `get-project-instructions` to understand project conventions, naming patterns, and constraints.
2. **List existing tasks**: Call `planner` with operation `list-tasks` (optionally filter by `project_id`) to check for duplicates or related work already planned. If a similar task exists, consider updating it rather than creating a new one.

## Phase 2 — Research & Exploration

Before creating any tasks, explore the codebase to understand scope and identify the files and patterns involved. This prevents creating tasks with incorrect assumptions.

### Token-Efficient Exploration Workflow

Use code-index operations in this order to minimize context consumption. Each step narrows focus before you spend tokens reading full files.

**Step 0 — Ensure index freshness with `diff` + re-index:**
ALWAYS start by running `code-index diff` to detect changed or added files. If there are changed or added files, index/re-index them using the code-index skill (spawn a code-index-agent sub-agent for batches). This ensures all subsequent operations work with up-to-date data. When omitted, `directories` defaults to `["."]` (project root).

```
code-index: diff
# → Scans entire project from root
# If changed/added files found → spawn code-index-agent to index them

# Or filter to specific directories:
code-index: diff (directories: ["lib", "test"], file_extensions: [".dart"])
```

**Step 1 — Get codebase overview with `overview`:**
Use `code-index overview` to get a compact listing of all indexed files with descriptions and export names. This gives you a "table of contents" in ~50-100 tokens. Use optional `path_pattern` or `file_type` filters to narrow scope.

**Step 2 — Discover relevant files with `search`:**
Use `code-index search` to find files related to the task. Search supports FTS5 full-text queries across file names, descriptions, export names, and variable names. You can also filter by:
- `export_name` / `export_kind` — find specific classes, functions, or methods
- `file_type` — restrict to e.g. "dart" files only
- `import_pattern` — find files importing a specific package
- `path_pattern` — restrict to a directory subtree

> **Search limitations:** `search` uses FTS5 full-text indexing. It works well for individual keywords and prefix matching (e.g., "valid", "User", "database"). It does NOT support phrase search — multi-word queries are treated as independent keywords joined by AND. For exact phrase matching or regex patterns, use `filesystem search-text` instead.

**Step 3 — Understand file API with `file-summary` or `show-file`:**
Use `code-index file-summary` to get a file's exports grouped by class, with descriptions and parameters. This is lighter than `show-file` — use it when you only need to understand what a file provides. Use `code-index show-file` when you also need imports, annotations, and timestamps.

**Step 4 — Map relationships with `dependents` and `dependencies`:**
- `code-index dependents` (path) — find all files that import a given path. Critical for impact analysis when planning changes.
- `code-index dependencies` (path) — get all imports for a file, classified as internal (indexed) or external. Helps understand what a file relies on.

**Step 5 — Find TODOs and annotations with `search-annotations`:**
Use `code-index search-annotations` to find TODO, FIXME, HACK, NOTE, and DEPRECATED annotations. Filter by kind, file path pattern, or message content. Useful for discovering existing plans, known issues, and technical debt related to the task area.

### Fallback Tools

Use these when code-index doesn't cover what you need:

- **filesystem list-content**: Use to explore directory structure or find files in unindexed directories.
- **filesystem read-file**: Use to examine specific files in detail — but only AFTER using show-file to confirm the file is relevant.
- **filesystem search-text**: Use for regex-based searching when you need pattern matching (code-index search is keyword/FTS-based, not regex).
- **git log/diff**: Use to understand recent changes and what areas of code are actively being modified.

### Token Economy

Prefer code-index operations to save context for planning decisions:

| Instead of... | Use... | Token savings |
|---|---|---|
| `filesystem list-content` on large dirs | `code-index overview` | ~50-100 tokens for entire codebase |
| `filesystem read-file` to understand a file | `code-index file-summary` | Lighter than `show-file` (no imports/annotations/timestamps) |
| `filesystem read-file` for full file details | `code-index show-file` | ~100-200 vs ~500-5000+ tokens |
| `filesystem search-text` scanning all files | `code-index search` with filters | Targeted results vs full-line matches |
| Manually searching imports to find dependents | `code-index dependents` | Instant reverse lookup |

**For large codebases**: If you need to analyze many files, consider spawning code-index-agent sub-agents to analyze batches of files to avoid running out of context.

Summarize your findings before moving to Phase 3. You should understand:
- Which files need to be modified
- What patterns/conventions exist in the codebase
- Dependencies and dependents of key files (use `dependents` and `dependencies`)
- TODOs or annotations related to the task area (use `search-annotations`)
- Any risks or cross-cutting concerns

## Phase 3 — Plan & Create Tasks

### Choosing the task pattern

**Single task with steps** — Use when the work is self-contained and can be done in one pass. This is the most common pattern.

**Parent task with sub-tasks** — Use when the plan has multiple independent parts that should be done in sequence, where each part is complex enough to warrant its own task with steps. The parent task title MUST be prefixed with "Parent:".

### Creating tasks

Create tasks using `planner` with operation `add-task`. Each task must have:

- **title**: Clear, concise description of the work. Prefix with "Parent:" for parent tasks.
- **project_id**: Must match the project conventions (check project instructions).
- **details**: Structured description including:
  - `## Background` — context and motivation
  - `## Purpose` — what this achieves
  - `## Files involved` — list key files that will be modified (from your research)
  - `## Acceptance Criteria` — bullet list of what "done" looks like
- **status**: Set to `draft`

### Adding steps to tasks

Add steps using `planner` with operation `add-step`. Each step should have:

- **title**: Action-oriented description
- **details**: Enough information to complete the step without ambiguity. Include specific file paths, what to change, and expected outcomes.
- **status**: Set to `todo`

### CRITICAL: Parent task step creation

When adding steps to a parent task, you MUST follow this exact order:

1. First, create ALL sub-tasks using `add-task` (each with their own steps)
2. Then, add steps to the parent task using `add-step` with the `sub_task_id` parameter set to the corresponding sub-task's id
3. Each parent task step title should match the sub-task title

Without `sub_task_id`, the planner-do-task skill cannot use `get-subtask-prompt` to fetch the sub-task details, breaking the parent task execution flow.

## Phase 4 — Verification

After creating all tasks:

1. Use `show-task` to review each created task
2. Verify steps are in logical order
3. Verify details are sufficient for someone to complete each step without additional context
4. Verify acceptance criteria are clear and testable
5. For parent tasks: verify every step has a `sub_task_id` set
6. For parent tasks: verify sub-tasks have their own steps defined

## Error Handling

- **project_id mismatch**: If `get-project-instructions` returns nothing or the project_id convention is unclear, ask the user to clarify or check the `.ai_coding_tool/INSTRUCTIONS.md` file.
- **Task creation fails**: Check that required fields (title, project_id) are provided. Retry once, then report the error to the user.
- **Duplicate task found**: If `list-tasks` shows a similar task already exists, inform the user and ask whether to update the existing task or create a new one.
- **code-index returns no results**: The index may be stale — use `code-index diff` to check for unindexed files. If the codebase is unindexed, fall back to `filesystem search-text` and `filesystem list-content`. Consider spawning `code-index` skill to index the codebase first.
- **code-index show-file returns nothing**: The file may not be indexed. Fall back to `filesystem read-file` for that specific file.

## Examples

### Example 1 — Exploration with code-index before planning

A user asks to add input validation to a form component. First explore:

```
# Step 0: Ensure index is fresh
code-index: diff (file_extensions: [".dart", ".tsx"])
# → 2 changed, 1 added → spawn code-index-agent to re-index them

# Step 1: Get codebase overview
code-index: overview
# → 15 files listed with descriptions and exports

# Step 2: Find relevant files
code-index: search (query: "validation", export_kind: "class")
# → Found ValidationUtils in src/utils/validation.dart
code-index: search (query: "RegisterForm")
# → Found RegisterForm class in src/components/RegisterForm.tsx

# Step 3: Understand file API without reading source
code-index: file-summary (path: "src/components/RegisterForm.tsx")
# → exports grouped by class: RegisterForm { build, _onSubmit }
# → no variables

code-index: show-file (path: "src/utils/validation.dart")
# → exports: validateEmail (function), validatePassword (function)
# → imports: dart:core
# → annotations: TODO "add password strength check" at line 15

# Step 4: Check impact — who else uses validation?
code-index: dependents (path: "src/utils/validation")
# → 3 files import this module: LoginForm, RegisterForm, ProfileForm

# Step 5: Check for related TODOs
code-index: search-annotations (kind: "TODO", path_pattern: "%validation%")
# → TODO: "add email format validation" in RegisterForm.tsx line 42
# → TODO: "add password strength check" in validation.dart line 15

# Only NOW read specific files that need detailed understanding
filesystem: read-file (path: "src/utils/validation.dart")
```

After research, create the task:

```
add-task:
  title: "Add input validation to user registration form"
  project_id: "my-project"
  details: |
    ## Background
    The user registration form at `./src/components/RegisterForm.tsx` currently accepts any input without validation.
    There are existing TODO annotations requesting email and password validation.
    ValidationUtils already exists in `./src/utils/validation.dart` with basic functions.
    3 other files depend on the validation module (LoginForm, RegisterForm, ProfileForm).
    
    ## Purpose
    Add client-side validation for email format, password strength, and required fields.
    
    ## Files involved
    - `./src/components/RegisterForm.tsx` (modify — add validation calls)
    - `./src/utils/validation.ts` (modify — add new validation functions)
    - `./src/components/__tests__/RegisterForm.test.tsx` (create/modify — add tests)
    
    ## Acceptance Criteria
    - Email field validates format using regex
    - Password requires minimum 8 characters, one uppercase, one number
    - All required fields show error messages when empty
    - Tests cover all validation rules
  status: draft

add-step (to above task):
  title: "Create validation utility functions"
  details: "Update `./src/utils/validation.ts` with functions: validateEmail(email: string), validatePassword(password: string), validateRequired(value: string). Each returns { valid: boolean, error?: string }. Note: 3 files depend on this module so ensure backward compatibility."
  
add-step:
  title: "Integrate validation into RegisterForm component"
  details: "Update `./src/components/RegisterForm.tsx` to import and use validation functions. Add error state for each field. Display error messages below invalid fields."

add-step:
  title: "Add tests for validation"
  details: "Create/update `./src/components/__tests__/RegisterForm.test.tsx` with tests for: valid email, invalid email, strong password, weak password, empty required fields."

add-step:
  title: "Verify and review changes"
  details: "Run existing tests to ensure nothing is broken. Review the implementation matches all acceptance criteria."
```

### Example 2 — Parent task with sub-tasks

A user asks to refactor the authentication system, which involves updating both the API layer and the UI components independently.

First create the sub-tasks:

```
add-task (sub-task 1):
  title: "Refactor auth API layer to use JWT tokens"
  project_id: "my-project"
  details: |
    ## Background
    The auth API currently uses session cookies. We need to switch to JWT tokens.
    ...
    ## Acceptance Criteria
    - API endpoints issue and validate JWT tokens
    - Token refresh flow works correctly
  status: draft
  (add steps to this sub-task...)

add-task (sub-task 2):
  title: "Update UI auth components for JWT flow"  
  project_id: "my-project"
  details: |
    ## Background
    After the API layer is updated to JWT, the UI components need to handle token storage and refresh.
    ...
    ## Acceptance Criteria
    - Login component stores JWT in memory
    - Token refresh happens automatically before expiry
  status: draft
  (add steps to this sub-task...)
```

Then create the parent task with steps referencing sub-tasks:

```
add-task (parent):
  title: "Parent: Refactor authentication system to JWT"
  project_id: "my-project"
  details: |
    ## Background
    Complete auth system refactoring from session cookies to JWT tokens.
    
    ## Sub-tasks (in order)
    1. Refactor auth API layer to use JWT tokens
    2. Update UI auth components for JWT flow
  status: draft

add-step (to parent task):
  title: "Refactor auth API layer to use JWT tokens"
  sub_task_id: "<id-of-sub-task-1>"

add-step (to parent task):
  title: "Update UI auth components for JWT flow"
  sub_task_id: "<id-of-sub-task-2>"
```

## Tool Reference

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project.

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.
