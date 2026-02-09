---
name: code-index
description: Index code files for quick and token efficient exploration and search in code base.
allowed-tools: filesystem, code-index
model: haiku
context: fork
agent: code-index-agent
---

1. Use diff operation of code-index tool to get a list of files that should be indexed
2. Spawn code-index-agent sub-agents and send a small batch of file paths for it to index
