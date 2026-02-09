---
name: planner-plan
description: Create a plan and use the planner tool to create one or more tasks with steps that describe how to perform the plan.
allowed-tools: planner, filesystem, git, fetch, convert, flutter, dart
context: fork
agent: planner-agent
---

ultrathink

The task should contain a title and details. The details gives background, purpose and acceptans criteria relevant to the task. The task also contains a series of steps if this is applicable. The task details together with the steps should contain the information needed in order to perform the task according to the plan.

- The task should be set to status draft
- The steps should be set to status todo

The most common task is an self-contained task with steps.

If the plan is complex it can be split into multiple tasks with steps.

If the tasks (called sub-tasks) need to be performed in a specific order, create a parent task that references the sub-tasks, one for each step. A step should contain the task title and the task id. A parent task should be prefixed with "Parent:" in the title. 

Use filesystem (dart-dev-mcp-fs) to read, search and edit files.
Use git (dart-dev-mcp-git) for git operations.
Use flutter (dart-dev-mcp-flutter-runner) or dart (dart-dev-mcp-dart-runner) to run code test, analyze or build the project.

Do not use native tools: Bash, Read, Write, Edit.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.
