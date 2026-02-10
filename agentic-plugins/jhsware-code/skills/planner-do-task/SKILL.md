---
name: planner-do-task
description: Perform a task found in the planner tool. The user passes the id of the task.
allowed-tools: planner, filesystem, git, fetch, convert, flutter-runner, dart-runner, code-index
model: opus
context: fork
agent: task-agent
---

Use code-index tool search operation when exploring the code base. It supports simple keyword searching. Use filesystem tool search as fallback.

Use the planner tool to fetch the task by task id.

There are two types of tasks.

1. Regular task with steps
2. Parent task with steps referencing sub-tasks

A parent task should be prefixed with "Parent:" in the title. Each step in a parent task should contain sub-task title and the step details should reference the sub-task by id.

When you perform a task, it is important that you follow the task process:

1. change status of the task to started
2. (skip if parent task)if we will edit files, use git (dart-dev-mcp-git) to create a git branch
3. check the memory of the task
4. perform all of the steps in the order they are listed
5. when you start with a step, change status to started
6. if the task is a parent task find the sub-task id of the step and invoke the /planner-do-task skill to complete the sub-task
7. when the step is done, change status to done
8. (skip if parent task) if files have been edited, use git (dart-dev-mcp-git) to commit the changes to the git branch
9. when all the steps are done, change status of task to done
10. (skip if parent task) if we are on a git branch, use git (dart-dev-mcp-git) to merge to master and change task status to merged

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project.

Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.
