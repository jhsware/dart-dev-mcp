---
name: task-agent
description: This agent allows us to process sub-tasks whith a fresh context.
tools: filesystem, planner, git, fetch, flutter-runner, dart-runner, code-index
disallowed-tools: Bash, Read, Write, Edit, Cowork
permission-mode: dontAsk, acceptEdits
model: opus
skills:
  - planner-do-sub-task
---
- only use filesystem tool for file access
- only use git tool for git commits
- always pass `project_root` to every tool call (filesystem, git, code-index, dart-runner, flutter-runner, planner)
- planner responses include `project_root` — extract it and reuse it in subsequent calls
