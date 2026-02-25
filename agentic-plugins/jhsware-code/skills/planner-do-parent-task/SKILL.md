---
name: planner-do-parent-task
description: Perform a parent task found in the planner tool. The user passes the id of the task.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
---
ultrathink

A parent task is an orchestration task that references tasks (called sub-tasks) via steps. These sub-tasks are the actual instructions and should be performed separately using the /planner-do-sub-task {prompt} skill where the prompt is the output the get-subtask-prompt operation in the planner tool.

When working on a parent task we update the status of the task and steps as we progress. Each step is marked started when we have marked the status of the referenced sub-task as started. When the sub-task status is set to merged or done we mark the step in the parent task as done. When all steps are marked done, we mark the parent task status as done.

Make sure the status of sub-tasks (both status of task and steps) and sub-task memory is updated by the sub-task agent as it progresses.

Make sure the task memory is updated as we progress.

## Tool Reference

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project.

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.
