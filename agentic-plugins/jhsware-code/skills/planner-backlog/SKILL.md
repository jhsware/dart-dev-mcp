---
name: planner-backlog
description: Add items to the backlog. Allows creating, updating, and listing backlog items categorized as features, improvements, bugs, or changes.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
---

ultrathink

## Purpose

Manage backlog items — features, improvements, bugs, and changes that need to be tracked before they are planned into a slate or assigned to a task.

## Workflow

Each project has it's own planning database and directory structure. When planning with multiple projects, it is very important to make sure you pass the correct project to project_dir for each operation.

### Step 1 — Understand the request

Parse what the user wants to add to or do with the backlog. They may:
- Describe one or more items to add (features, bugs, improvements, changes)
- Ask to list or search existing items
- Ask to update an item's status, type, or details
- Ask to close items that are done

### Step 2 — Get project context

1. Call `planner` with operation `get-project-instructions` to understand project conventions.
2. Call `planner` with operation `list-items` (optionally filter by `type` or `status`) to see existing backlog items and avoid duplicates.

### Step 3 — Execute the requested operation

#### Adding items

For each item to add:
- Determine the appropriate **type** (see reference table below)
- Use `planner` with operation `add-item`:
  - `title`: Clear, concise description (imperative form, e.g. "Add user authentication")
  - `details`: Markdown with context, motivation, and acceptance criteria where relevant
  - `type`: One of the valid types
  - Status defaults to `open`

#### Listing items

Use `planner` with operation `list-items`. Available filters:
- `type` — filter by type (feature, improvement, bug, change)
- `status` — filter by status (open, closed)
- `search_query` — full-text search across title and details

#### Updating items

Use `planner` with operation `update-item`:
- `id`: The item ID (required)
- Optional fields to update: `title`, `details`, `type`, `status`

#### Viewing item details

Use `planner` with operation `show-item`:
- `id`: The item ID (required)
- Returns item details including edit history

### Step 4 — Verify

After creating or updating items, list items to confirm the changes were applied correctly.

## Item Type Reference

| Type | Description | Examples |
|---|---|---|
| `feature` | New functionality that doesn't exist yet | "Add dark mode", "Implement search" |
| `improvement` | Enhancement to existing functionality | "Speed up search results", "Better error messages" |
| `bug` | Something that's broken or not working correctly | "Login fails on Safari", "Incorrect total calculation" |
| `change` | Refactoring, tech debt, or general changes | "Migrate to new API version", "Update dependencies" |

## Item Lifecycle

- An item with status `open` that does NOT belong to any slate is considered **in the backlog** (unplanned).
- An item assigned to a slate (via `add-item-to-slate`) is considered **planned** for that slate.
- An item linked to a task (via `add-item-to-task`) is considered **in progress**.
- An item with status `closed` is considered **done**.

## Tool Reference

All tool calls MUST include the `project_dir` parameter matching one of the registered project directories. Omitting `project_dir` will return a validation error.

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project. Use the `pub-run` operation for code generation (e.g. `build_runner build --delete-conflicting-outputs`). For monorepo sub-packages, pass the optional `working_dir` parameter (relative to `project_dir`, e.g. `working_dir="packages/foo"`).

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.