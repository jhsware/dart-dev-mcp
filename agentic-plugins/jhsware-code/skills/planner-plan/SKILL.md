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

**Tool selection for exploration:**

- **code-index search** (preferred): Use for keyword discovery and finding relevant files quickly. Supports simple keyword searching across indexed files.
- **filesystem list-content**: Use to understand directory structure and find files by path patterns.
- **filesystem read-file**: Use to examine specific files in detail once you know which files matter.
- **filesystem search-text**: Use as regex fallback when code-index doesn't find what you need, or when you need pattern-based searching.
- **git log/diff**: Use to understand recent changes and what areas of code are actively being modified.

**For large codebases**: If you need to analyze many files, consider spawning code-index-agent sub-agents to analyze batches of files to avoid running out of context.

Summarize your findings before moving to Phase 3. You should understand:
- Which files need to be modified
- What patterns/conventions exist in the codebase
- Any dependencies or risks

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
- **Exploration hits dead ends**: If code-index returns no results, fall back to filesystem search-text with broader patterns. If the codebase structure is unclear, use filesystem list-content to map the directory tree first.

## Examples

### Example 1 — Simple task with steps

A user asks to add input validation to a form component.

After research, create:

```
add-task:
  title: "Add input validation to user registration form"
  project_id: "my-project"
  details: |
    ## Background
    The user registration form at `./src/components/RegisterForm.tsx` currently accepts any input without validation.
    
    ## Purpose
    Add client-side validation for email format, password strength, and required fields.
    
    ## Files involved
    - `./src/components/RegisterForm.tsx`
    - `./src/utils/validation.ts` (new file)
    - `./src/components/__tests__/RegisterForm.test.tsx`
    
    ## Acceptance Criteria
    - Email field validates format using regex
    - Password requires minimum 8 characters, one uppercase, one number
    - All required fields show error messages when empty
    - Tests cover all validation rules
  status: draft

add-step (to above task):
  title: "Create validation utility functions"
  details: "Create `./src/utils/validation.ts` with functions: validateEmail(email: string), validatePassword(password: string), validateRequired(value: string). Each returns { valid: boolean, error?: string }."
  
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
