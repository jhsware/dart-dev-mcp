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
- [ ] Step 5: If coding task - offer to merge the branch
- [ ] Step 6: If coding task - when code is merged to master, set task to merged

When processing a step:
- [ ] Step 1: Set step status to started
- [ ] Step 2: Perform the step
- [ ] Step 3: If coding task - make logical commits
- [ ] Step 4: Use task memory to store context for later steps
- [ ] Step 5: When step is completed, mark step done

## Tool Reference

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project.

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.
