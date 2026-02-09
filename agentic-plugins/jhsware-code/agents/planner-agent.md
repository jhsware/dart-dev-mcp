---
name: planner-agent
description: Create a plan and use the planner tool to create one or more tasks with steps that describe how to perform the plan.
tools: filesystem, planner, git, fetch, convert, flutter, dart, code-index
disallowed-tools: Bash, Read, Write, Edit
permission-mode: dontAsk, plan
model: opus
skills:
  - planner-plan
---

To analyse files, create code-index-agent sub-agents and analyse batches of files to avoid running out of context.
