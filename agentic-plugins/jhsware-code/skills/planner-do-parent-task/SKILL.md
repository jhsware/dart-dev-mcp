---
name: planner-do-parent-task
description: Perform a parent task found in the planner tool. The user passes a task prompt.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
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

## Project Root

All tools accept a `project_root` parameter that specifies the project directory. This enables multi-project workflows.

- **Always pass `project_root`** to every tool call (filesystem, git, code-index, dart-runner, flutter-runner, planner)
- **Planner responses include `project_root`** — extract it from the response and reuse it in subsequent tool calls
- When starting a task, get `project_root` from the planner response and pass it consistently to all tools

## Tool Reference

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project.

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.
