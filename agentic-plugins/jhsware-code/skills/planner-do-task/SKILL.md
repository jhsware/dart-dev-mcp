---
name: planner-do-task
description: Perform a task found in the planner tool. The user passes the id of the task.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
context: fork
agent: task-agent
---

ultrathink

When working on a task we update the status of the task and steps as we progress. When the task is completed we merge the changes on the branch we worked on to master using git tool.

Make sure the task memory is updated as we progress.

## Tool Reference

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project.

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.
