---
name: planner-do-parent-task
description: Perform a parent task found in the planner tool. The user passes a task prompt.
allowed-tools: planner, filesystem, git, fetch, flutter_runner, dart_runner, code_index
model: opus
---
ultrathink

A parent task is an orchestration task that references tasks (called sub-tasks) via steps. These sub-tasks are the actual instructions and should be performed separately using the /planner-do-sub-task {prompt} skill where the prompt is the output the get-subtask-prompt operation in the planner tool.

When working on a parent task:
- [ ] Step 1: Set task status to started
- [ ] Step 2: Process each step individually
- [ ] Step 3: When all steps are done, set task to done
- [ ] Step 4: If task is related to a slate, and all items in that slate is marked done, set slate to done

When processing a step:
- [ ] Step 1: Set step status to started
- [ ] Step 2: Fetch sub-task prompt using get-subtask-prompt
- [ ] Step 3: Process using /planner-do-sub-task, passing sub-task prompt
- [ ] Step 4: When sub-task is completed, mark step done

Make sure the task memory is updated as we progress.

## Resuming Parent Task – Verify Sub-Task Completeness
When the parent task is resumed, verify that the dispatched sub-task is completed. Also verify that the sub-task step and task status has been updated. Verify that all changed files have been committed to the correct branch. If the sub-task wasn't properly completed, re-dispatch the sub-task to allow it to fix issues.

## Working With Branches
We have implemented git worktree support. Make sure you use the same worktree for all sub-tasks. Do not spawn new worktrees and if there is a worktree that is related to this parent task from a previous run, use that worktree instead of creating a new worktree.

Using worktrees allows us to work on tasks in parallel. But creating a worktree comes at a cost so we don't want to create more than necessary.

## Tool Reference

All tool calls MUST include the `project_dir` parameter matching one of the registered project directories. Omitting `project_dir` will return a validation error.

Use filesystem (jhsware_code_filesystem) to read, search and edit files.
Use git (jhsware_code_git) for git operations.
Use flutter (jhsware_code_flutter_runner) or dart (jhsware_code_dart_runner) to run code test, analyze or build the project. Use the `pub-run` operation for code generation (e.g. `build_runner build --delete-conflicting-outputs`). For monorepo sub-packages, pass the optional `working_dir` parameter (relative to `project_dir`, e.g. `working_dir="packages/foo"`).

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.