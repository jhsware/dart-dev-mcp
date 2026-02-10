---
name: task-agent
description: Perform a task found in the planner tool. The user passes the id of the task.
tools: filesystem, planner, git, fetch, flutter-runner, dart-runner, code-index
disallowed-tools: Bash, Read, Write, Edit, Cowork
permission-mode: dontAsk, acceptEdits
model: opus
skills:
  - planner-do-task
  - code-index
---


