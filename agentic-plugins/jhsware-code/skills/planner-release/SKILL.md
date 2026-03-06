---
name: planner-release
description: Create releases and select appropriate backlog items for them. An item is part of the backlog if it doesn't belong to any release.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
---

ultrathink

## Purpose

Manage releases — group backlog items into coherent release scopes, track what's planned for each release, and prepare for implementation planning.

## Workflow

### Step 1 — Understand the release scope

Parse what the user wants:
- Create a new release with a specific theme, scope, or goals
- Add or remove items from an existing release
- List releases or view release details
- Update release information

### Step 2 — Get project context

1. Call `planner` with operation `get-project-instructions` to understand project conventions and the project_id to use.
2. Call `planner` with operation `list-releases` (optionally filter by `project_id`) to see existing releases.
3. Call `planner` with operation `list-items` to see the full backlog. Items with status `open` are available for assignment to releases.

### Step 3 — Execute the requested operation

#### Creating a release

Use `planner` with operation `add-release`:
- `title`: Clear release name (e.g. "v2.0 — Authentication Overhaul", "Sprint 12")
- `project_id`: From project instructions
- `notes`: Markdown describing release goals, scope, and any constraints

#### Selecting items for a release

After creating (or when updating) a release, review the backlog and select appropriate items:

1. List backlog items: `planner list-items` with `status: open`
2. For each item that fits the release scope:
   - Use `planner` with operation `add-item-to-release`: requires `release_id` and `item_id`
   - Explain to the user why each item was selected
3. If an item is already assigned to another release, inform the user (items can belong to multiple releases)

#### Removing items from a release

Use `planner` with operation `remove-item-from-release`:
- `release_id`: The release ID (required)
- `item_id`: The item ID to remove (required)

#### Viewing release details

Use `planner` with operation `show-release`:
- `id`: The release ID (required)
- Returns release details including all assigned items

#### Updating a release

Use `planner` with operation `update-release`:
- `id`: The release ID (required)
- Optional fields to update: `title`, `notes`

#### Listing releases

Use `planner` with operation `list-releases`:
- Optional filter: `project_id`
- Returns releases with item counts

### Step 4 — Review

Call `planner show-release` to verify the release has the correct items assigned.

Present a summary to the user:
- Release title and goals
- Number of items by type (features, improvements, bugs, changes)
- Any items that are also in other releases

### Step 5 — Suggest next steps

After creating a release with items, suggest the user can:
- Use `/planner-plan` to create implementation tasks from the release items
- Use `/planner-backlog` to add more items if the backlog needs updating

## Release Lifecycle

1. **Create release** — Define scope, goals, and title
2. **Assign items** — Select backlog items that fit the release scope
3. **Plan tasks** — Use `/planner-plan` to create implementation tasks (tasks can be linked to items via `add-item-to-task`)
4. **Execute** — Work through tasks using `/planner-do-task` or `/planner-do-parent-task`
5. **Close items** — As work is completed, update item status to `closed`

## Tool Reference

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project.

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.
