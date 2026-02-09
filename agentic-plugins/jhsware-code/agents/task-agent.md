---
name: task-agent
description: Perform a task found in the planner tool. The user passes the id of the task.
tools: filesystem, planner, git, fetch, flutter, dart, code-index
disallowed-tools: Bash, Read, Write, Edit
permission-mode: dontAsk, acceptEdits
model: opus
skills:
  - planner-do-task
  - code-index
---


