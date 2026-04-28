---
name: planner-slate
description: Create slates and select appropriate backlog items for them. An item is part of the backlog if it doesn't belong to any slate.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
---

ultrathink

## Purpose

Manage slates — group backlog items into coherent slate scopes, track what's planned for each slate, and prepare for implementation planning.

## Workflow

### Step 1 — Understand the slate scope

Parse what the user wants:
- Create a new slate with a specific theme, scope, or goals
- Add or remove items from an existing slate
- List slates or view slate details
- Update slate information

### Step 2 — Get project context

1. Call `planner` with operation `get-project-instructions` to understand project conventions.
2. Call `planner` with operation `list-slates` to see existing slates.
3. Call `planner` with operation `list-items` to see the full backlog. Items with status `open` are available for assignment to slates.

### Step 3 — Execute the requested operation

#### Creating a slate

Use `planner` with operation `add-slate`:
- `title`: Clear slate name (e.g. "v2.0 — Authentication Overhaul", "Sprint 12")
- `notes`: Markdown describing slate goals, scope, and any constraints

#### Selecting items for a slate

After creating (or when updating) a slate, review the backlog and select appropriate items:

1. List backlog items: `planner list-items` with `status: open`
2. For each item that fits the slate scope:
   - Use `planner` with operation `add-item-to-slate`: requires `release_id` and `item_id`
   - Explain to the user why each item was selected
3. If an item is already assigned to another slate, inform the user (items can belong to multiple slates)

#### Removing items from a slate

Use `planner` with operation `remove-item-from-slate`:
- `release_id`: The slate ID (required)
- `item_id`: The item ID to remove (required)

#### Viewing slate details

Use `planner` with operation `show-slate`:
- `id`: The slate ID (required)
- Returns slate details including all assigned items

#### Updating a slate

Use `planner` with operation `update-slate`:
- `id`: The slate ID (required)
- Optional fields to update: `title`, `notes`

#### Listing slates

Use `planner` with operation `list-slates`:
- Returns slates with item counts

### Step 4 — Review

Call `planner show-slate` to verify the slate has the correct items assigned.

Present a summary to the user:
- Slate title and goals
- Number of items by type (features, improvements, bugs, changes)
- Any items that are also in other slates

### Step 5 — Suggest next steps

After creating a slate with items, suggest the user can:
- Use `/planner-plan` to create implementation tasks from the slate items
- Use `/planner-backlog` to add more items if the backlog needs updating

## Slate Lifecycle

1. **Create slate** — Define scope, goals, and title
2. **Assign items** — Select backlog items that fit the slate scope
3. **Plan tasks** — Use `/planner-plan` to create implementation tasks (tasks can be linked to items via `add-item-to-task`)
4. **Execute** — Work through tasks using `/planner-do-task` or `/planner-do-parent-task`
5. **Close items** — As work is completed, update item status to `closed`

## Tool Reference

All tool calls MUST include the `project_dir` parameter matching one of the registered project directories. Omitting `project_dir` will return a validation error.

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project. Use the `pub-run` operation for code generation (e.g. `build_runner build --delete-conflicting-outputs`). For monorepo sub-packages, pass the optional `working_dir` parameter (relative to `project_dir`, e.g. `working_dir="packages/foo"`).

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.