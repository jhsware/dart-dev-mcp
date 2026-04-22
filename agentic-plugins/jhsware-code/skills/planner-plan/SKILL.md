---
name: planner-plan
description: Create a plan and use the planner tool to create one or more tasks with steps that describe how to perform the plan. Can also create tasks from slates, linking tasks to backlog items.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
context: fork
agent: planner-agent
---

ultrathink

Each project has it's own planning database and directory structure. When planning with multiple projects, it is very important to make sure you pass the correct project to project_dir for each operation.

## Phase 1 — Setup

Before doing anything else:

- [ ] Step 1:. **Ask user** if they want the created task/tasks to have status draft or todo.
- [ ] Step 2: **Read project instructions**: Call `planner` with operation `get-project-instructions` to understand project conventions, naming patterns, and constraints.
- [ ] Step 3: **List existing tasks**: Call `planner` with operation `list-tasks` to check for duplicates or related work already planned. If a similar task exists, consider updating it rather than creating a new one.
- [ ] Step 4: **Check for slate context**: If the user mentions a slate or passes a release_id, call `planner` with operation `show-slate` to get the slate details and its items. This enables slate-based planning (see Phase 2a).

## Phase 2 — Research & Exploration

Before creating any tasks, explore the codebase to understand scope and identify the files and patterns involved. This prevents creating tasks with incorrect assumptions.

### Token-Efficient Exploration Workflow

- **filesystem list-content**: Use to explore directory structure or find files in unindexed directories.
- **filesystem read-file**: Use to examine specific files in detail — but only AFTER using show-file to confirm the file is relevant.
- **filesystem search-text**: Use for regex-based searching when you need pattern matching (code-index search is keyword/FTS-based, not regex).
- **git log/diff**: Use to understand recent changes and what areas of code are actively being modified.

### Token Economy

**For large codebases**: If you need to analyze many files, consider spawning code-index-agent sub-agents to analyze batches of files to avoid running out of context.

Summarize your findings before moving to Phase 3. You should understand:
- Which files need to be modified
- What patterns/conventions exist in the codebase
- Dependencies and dependents of key files (use `dependents` and `dependencies`)
- TODOs or annotations related to the task area (use `search-annotations`)
- Any risks or cross-cutting concerns

## Phase 2a — Slate-based Planning

When creating tasks from a slate (user mentions a slate or passes a release_id):

- [ ] Step 1: **Get the slate and it's items**: Call `planner show-slate` with the slate ID to get the slate details and all assigned items. Details about the slate is specified in the linked items.

- [ ] Step 2: **Change status of slate to started**

- [ ] Step 3: **Analyze and group items**: Review the items and group related ones that could be implemented together in a single task. Consider: 
   - Items that affect the same files or modules
   - Items that have logical dependencies on each other
   - Items of the same type that can be batched (e.g. multiple bugs in one area)

- [ ] Step 4: **Still do Phase 2 exploration**: Codebase exploration is still needed to create accurate tasks with correct file references. Use the item descriptions to guide your exploration — focus on files and areas mentioned in the items.

- [ ] Step 5: **Create tasks linked to items**: For each task created in Phase 3:
   - It is very important to read the item details to understand what the task should accomplish, the title is not enough
   - Reference the backlog items it addresses in the task details
   - After creating the task and its steps, link each relevant item using `planner` with operation `add-item-to-task` (requires `task_id` and `item_id`)
   - A single task can address multiple related items
   - An item can be linked to multiple tasks if needed

- [ ] Step 6: **For complex slates with many items**:
   - Consider using the parent task pattern
   - Group items by theme/area into sub-tasks
   - Each sub-task links to its specific items via `add-item-to-task`



## Phase 3 — Plan & Create Tasks

### Choosing the task pattern

**Single task with steps** — Use when the work is self-contained and can be done in one pass. This is the most common pattern.

**Parent task with sub-tasks** — Use when the plan has multiple independent parts that should be done in sequence, where each part is complex enough to warrant its own task with steps. The parent task title MUST be prefixed with "Parent:".

### Creating tasks

Create tasks using `planner` with operation `add-task`. Each task must have:

- **title**: Clear, concise description of the work. Prefix with "Parent:" for parent tasks.
- **details**: Structured description including:
  - `## Background` — context and motivation
  - `## Purpose` — what this achieves
  - `## Files involved` — list key files that will be modified (from your research)
  - `## Acceptance Criteria` — bullet list of what "done" looks like
  - If planning from a slate: `## Backlog Items` — list the item IDs and titles this task addresses
- **status**: Set to `draft`

> **IMPORTANT: Do NOT include step descriptions in the task details.** The details section should only contain background, purpose, files involved, backlog items, and acceptance criteria. Steps are added separately via `add-step` operations and will appear under a dedicated `## Steps to perform` header in the task execution prompt. Including step content in details confuses the LLM during task execution because it cannot distinguish between task context and actual steps to perform.

### Adding steps to tasks

Add steps using `planner` with operation `add-step`. Each step should have:

- **title**: Action-oriented description
- **details**: Enough information to complete the step without ambiguity. Include specific file paths, what to change, and expected outcomes.
- **status**: Set to `todo`


### Linking items to tasks (slate-based planning)

After creating a task and its steps, link backlog items to it:

```
planner: add-item-to-task (task_id: "<task-id>", item_id: "<item-id>")
```

This creates a many-to-many relationship — a task can have multiple items and an item can be linked to multiple tasks.


### CRITICAL: Parent task step creation

When adding steps to a parent task, you MUST follow this exact order:

- [ ] Step 1: First, create ALL sub-tasks using `add-task` (each with their own steps)
- [ ] Step 2: Then, add steps to the parent task using `add-step` with the `sub_task_id` parameter set to the corresponding sub-task's id
- [ ] Step 3: Each parent task step title should match the sub-task title

Without `sub_task_id`, the planner-do-parent-task skill cannot use `get-subtask-prompt` to fetch the sub-task details, breaking the parent task execution flow.

## Phase 4 — Verification

After creating all tasks:

- [ ] Step 1: Use `show-task` to review each created task
- [ ] Step 2: Verify steps are in logical order
- [ ] Step 3: Verify details are sufficient for someone to complete each step without additional context
- [ ] Step 4: Verify acceptance criteria are clear and testable
- [ ] Step 5: For parent tasks: verify every step has a `sub_task_id` set
- [ ] Step 6: For parent tasks: verify sub-tasks have their own steps defined
- [ ] Step 7: For slate-based tasks: verify all slate items are linked to at least one task via `add-item-to-task`

## Error Handling

- **Task creation fails**: Check that required fields (title) are provided. Retry once, then report the error to the user.
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

### Example 3 — Planning from a slate

A user says "Plan tasks for slate X" or passes a release_id:

```
# Step 1: Get slate details
planner: show-slate (id: "<slate-id>")
# → Slate: "v2.1 — Performance & Polish"
# → Items:
# →   item-1: [improvement] "Speed up dashboard loading"
# →   item-2: [improvement] "Add caching to API responses"
# →   item-3: [bug] "Fix memory leak in chart component"
# →   item-4: [feature] "Add export to CSV"

# Step 2: Group related items
# Items 1+2 are both about performance → single task
# Item 3 is an independent bug fix → single task
# Item 4 is independent → single task

# Step 3: Explore codebase (Phase 2) for each group...

# Step 4: Create tasks and link items
add-task:
  title: "Improve dashboard and API performance"
  details: |
    ## Background
    ...
    ## Backlog Items
    - item-1: Speed up dashboard loading
    - item-2: Add caching to API responses
  ...

# After task creation:
planner: add-item-to-task (task_id: "<perf-task-id>", item_id: "<item-1-id>")
planner: add-item-to-task (task_id: "<perf-task-id>", item_id: "<item-2-id>")

add-task:
  title: "Fix memory leak in chart component"
  ...
planner: add-item-to-task (task_id: "<fix-task-id>", item_id: "<item-3-id>")

add-task:
  title: "Add CSV export functionality"
  ...
planner: add-item-to-task (task_id: "<csv-task-id>", item_id: "<item-4-id>")
```

## Tool Reference

All tool calls MUST include the `project_dir` parameter matching one of the registered project directories. Omitting `project_dir` will return a validation error.

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project. Use the `pub-run` operation for code generation (e.g. `build_runner build --delete-conflicting-outputs`).

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.