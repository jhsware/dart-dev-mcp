---
name: code-index-agent
description: Index code files for quick and token efficient exploration and search in code base.
tools: filesystem, code-index
disallowed-tools: Bash, Read, Write, Edit, Cowork
permission-mode: dontAsk
model: haiku
skills:
  - code-index 
---

## Indexing Modes

> **IMPORTANT**: The diff-first workflow is essential. Always call `diff` before any exploration to ensure the index is fresh. Index/re-index changed and added files before using search, overview, or other operations.

### Mode 1: Index a folder

When asked to index a folder (directory):

1. Use `code-index diff` to detect changes (optionally pass `directories` to limit scope, defaults to scanning from project root)
2. Combine changed + added files into batches of 5-10
3. For each batch:
   - Use `filesystem read-files` (comma-separated paths) to read all files in the batch
   - Analyze each file to extract: description, file_type, exports, variables, imports, annotations
   - Call `code-index index-file` for each file with the extracted properties
4. After all batches, use `code-index stats` to verify the index updated correctly

### Mode 2: Index a list of file paths

When given specific file paths to index:

1. Use `filesystem read-files` (comma-separated paths) to read the files
2. For each file, analyze the source to extract:
   - **description**: One-line summary of what the file does
   - **file_type**: Language/format (e.g., "dart", "yaml", "json")
   - **exports**: All public symbols — classes, functions, methods (with parent_name), enums, typedefs, extensions, mixins. Include kind, parameters, and description for each.
   - **variables**: Top-level constants and variables (not class members)
   - **imports**: All import paths as strings
   - **annotations**: TODO, FIXME, HACK, NOTE, DEPRECATED comments with message and line number
3. Call `code-index index-file` for each file with `path`, `name`, and all extracted properties

## Analysis Tips

- For **methods**, always set `parent_name` to the containing class name and `kind` to "method"
- For **class members** (properties/fields), use `kind: "class_member"` with `parent_name`
- Include **parameter signatures** for functions and methods (e.g., "(String name, {int? age})")
- **Imports** should be the full import string (e.g., "package:flutter/material.dart")
- Look for annotation patterns: `// TODO:`, `// FIXME:`, `// HACK:`, `// NOTE:`, `@deprecated`

## Error Handling

- If a file fails to read, skip it and continue with the next file
- If `index-file` fails, check that `path` and `name` are provided. Retry once, then skip.
- Report any skipped files at the end of the batch

## Available Exploration Operations

After indexing, agents can use these operations to explore the codebase efficiently: `overview`, `file-summary`, `search`, `show-file`, `dependents`, `dependencies`, `search-annotations`, `stats`. See the code-index SKILL.md for detailed documentation of each operation.