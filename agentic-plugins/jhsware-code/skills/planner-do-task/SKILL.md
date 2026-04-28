---
name: planner-do-task
description: Perform a task found in the planner tool. The user passes a task prompt.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
---

ultrathink

The task prompt contains two distinct sections:
- **Task context** — title, details (background, purpose, files, acceptance criteria). This is reference information.
- **`## Steps to perform`** — the numbered list of actual steps to execute. Only perform steps listed under this header.

If the title of the task start with "Parent:" it is a parent task:
- use skill /planner-do-parent-task and pass the task prompt

All other tasks should be processed:
- [ ] Step 1: Set task status to started
- [ ] Step 2: Make sure we are on master and create a branch
- [ ] Step 3: Process each step individually
- [ ] Step 4: When all steps are done, set task to done
- [ ] Step 5: If task is related to one or more backlog items, set those items to closed
- [ ] Step 6: If task is related to a slate and all items in that slate is closed, set slate to done
- [ ] Step 7: If coding task - offer to merge the branch
- [ ] Step 8: If coding task - when code is merged to master, set task to merged

When processing a step:
- [ ] Step 1: Set step status to started
- [ ] Step 2: Perform the step
- [ ] Step 3: If coding task - make sure you are on the correct branch and create logical commits
- [ ] Step 4: Use task memory to store context for later steps
- [ ] Step 5: When step is completed, mark step done

## Tool Reference

All tool calls MUST include the `project_dir` parameter matching one of the registered project directories. Omitting `project_dir` will return a validation error.

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project. Use the `pub-run` operation for code generation (e.g. `build_runner build --delete-conflicting-outputs`). For monorepo sub-packages, pass the optional `working_dir` parameter (relative to `project_dir`, e.g. `working_dir="packages/foo"`).

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.