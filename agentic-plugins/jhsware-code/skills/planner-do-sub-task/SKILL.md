---
name: planner-do-sub-task
description: "Perform a task found in the planner tool. The user passes a sub-task prompt from planner: get-subtask-prompt."
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
context: fork
agent: task-agent
---

ultrathink

When working on a task:
- [ ] Step 1: Set task status to started
- [ ] Step 2: Make sure we are on master and create a branch
- [ ] Step 3: Process each step individually
- [ ] Step 4: When all steps are done, set task to done
- [ ] Step 5: If task is related to one or more backlog items, set those items to closed
- [ ] Step 6: If task is related to a slate and all items in that slate is closed, set slate to done
- [ ] Step 7: If coding task - offer to merge the branch
- [ ] Step 8: If coding task - when code is merged to master, set task to merged
- [ ] Step 9: Make sure the parent task step status is updated


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
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project.

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.