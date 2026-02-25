---
name: planner-do-task
description: Perform a task found in the planner tool. The user passes the id of the task.
allowed-tools: planner
model: sonnet
---

If the task title starts with the text "Parent:" this is a parent task and we should use the skill /planner-do-parent-task {task-prompt} to perform the task.

All other tasks should use the skill /planner-do-sub-task {task-prompt} to perform the task.


## Tool Reference
Do not use native tools: Bash, Read, Write, Edit, Git.
Do not delete files, ask user to delete them.
Do not run bash commands, ask user to do this.
