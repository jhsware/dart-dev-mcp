---
name: code-index
description: Index code files for quick and token efficient exploration and search in code base.
allowed-tools: filesystem, code-index
model: haiku
context: fork
agent: code-index-agent
---

## Purpose

The code-index maintains a searchable database of file metadata (exports, imports, variables, annotations) so that agents can explore and search the codebase without reading full source files. This saves significant context tokens — `show-file` returns ~100-200 tokens vs ~500-5000+ tokens for reading source.

## Indexing Workflow

> **IMPORTANT: Always start with `diff`**
> Before any exploration or search, always run `code-index diff` first to detect changed/new files. Then index/re-index those files. This ensures the index is fresh for subsequent operations.

### Step 1 — Detect files that need indexing

Use `code-index diff` to compare the filesystem against the index:

```
code-index: diff (directories: ["lib", "test"], file_extensions: [".dart"])
# → Returns: changed: [...], added: [...], deleted: [...]
```

Parameters:
- `directories` (required): Array of directories to scan relative to project root
- `file_extensions` (optional): Array of extensions to include, e.g. `[".dart", ".yaml"]`
- `remove_deleted` (optional, default true): Automatically remove deleted files from the index

### Step 2 — Read and analyze files

For each file that needs indexing (changed + added from diff), read the source:

```
filesystem: read-file (path: "lib/src/my_class.dart")
```

For large batches (>10 files), spawn code-index-agent sub-agents with batches of 5-10 file paths each to avoid exhausting context.

### Step 3 — Index each file

Use `code-index index-file` to add/update each file in the index:

```
code-index: index-file
  path: "lib/src/models/user.dart"
  name: "user.dart"
  description: "User model with authentication properties"
  file_type: "dart"
  exports:
    - name: "User"
      kind: "class"
      description: "Represents an authenticated user"
      parameters: "({required String id, required String email, String? name})"
    - name: "fromJson"
      kind: "method"
      parent_name: "User"
      description: "Create User from JSON map"
      parameters: "(Map<String, dynamic> json)"
    - name: "toJson"
      kind: "method"
      parent_name: "User"
      description: "Convert User to JSON map"
  variables:
    - name: "defaultAvatarUrl"
      description: "Default avatar URL for users without profile pictures"
  imports:
    - "dart:convert"
    - "package:my_app/src/utils/json_helpers.dart"
  annotations:
    - kind: "TODO"
      message: "Add email validation"
      line: 42
    - kind: "DEPRECATED"
      message: "Use User.fromJson instead"
      line: 15
```

### index-file parameter reference

| Parameter | Required | Description |
|---|---|---|
| `path` | Yes | Relative path from project root |
| `name` | Yes | File name (e.g., "user.dart") |
| `description` | No | What the file does |
| `file_type` | No | Language/type (e.g., "dart", "yaml", "json") |
| `exports` | No | Array of exported symbols |
| `variables` | No | Array of top-level variables |
| `imports` | No | Array of import path strings |
| `annotations` | No | Array of TODO/FIXME/HACK/NOTE/DEPRECATED |

**Export object properties:** `name` (required), `kind` (required: class, method, function, class_member, enum, typedef, extension, mixin), `parameters` (optional), `description` (optional), `parent_name` (optional — for methods/members, the owning class)

**Variable object properties:** `name` (required), `description` (optional)

**Annotation object properties:** `kind` (required: TODO, FIXME, HACK, NOTE, DEPRECATED), `message` (optional), `line` (optional)

## Analysis Guidelines

When analyzing a source file to extract index properties:

1. **Exports**: Identify all public classes, functions, methods, enums, typedefs, extensions, and mixins. For methods, set `parent_name` to the containing class. Include parameter signatures.
2. **Variables**: Identify top-level constants and variables (not local or class members — those go as exports with kind `class_member`).
3. **Imports**: Extract all import statements as path strings.
4. **Annotations**: Look for `// TODO:`, `// FIXME:`, `// HACK:`, `// NOTE:`, and `@deprecated` / `// DEPRECATED:` comments. Include the message and line number.
5. **Description**: Write a concise one-line summary of what the file does.

## Batch Indexing Strategy

When indexing a large number of files:

- Process files in batches of 5-10 per sub-agent invocation
- Group files by directory or feature area for coherent batches
- After all batches complete, use `code-index stats` to verify the index is complete
- Use `code-index diff` again to confirm no files were missed

## Exploration Operations Reference

After indexing, these operations are available for exploring the codebase:

- **overview** — Compact listing of all indexed files with path, description, file_type, and export names as "name (kind)" strings. Use `path_pattern` and `file_type` to filter. Returns ~50-100 tokens for an entire codebase.
- **file-summary** (path) — Shows a file's exports grouped by class, with descriptions and parameters. Lighter than `show-file` (excludes imports, annotations, timestamps). Use to understand a file's API surface.
- **search** (query + filters) — FTS5 keyword search across file names, descriptions, export names, variable names. Supports filters: `export_name`, `export_kind`, `file_type`, `path_pattern`, `import_pattern`, `description_pattern`. **Limitation:** keyword-based only, no phrase search. Multi-word queries match independent keywords joined by AND. For phrase/regex, use `filesystem search-text`.
- **show-file** (path) — Full indexed info including exports, imports, variables, and annotations. Use when you need the complete picture.
- **dependents** (path) — Find all files that import a given path.
- **dependencies** (path) — Get a file's imports classified as internal (indexed) or external.
- **search-annotations** — Find TODO/FIXME/HACK/NOTE/DEPRECATED across the codebase. Filter by `kind`, `path_pattern`, `message_pattern`, `file_type`.
- **stats** — Aggregate counts: files by type, exports by kind, top imports, annotations by kind.

## Error Handling

- **File read fails**: Skip the file and continue with the next. Report skipped files at the end.
- **index-file fails**: Check that `path` and `name` are provided (required fields). Retry once, then skip and report.
- **Large file**: If a file is too large to fit in context, focus on extracting exports and imports (the most useful parts for search). Skip detailed parameter extraction if needed.
