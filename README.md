# Dart Dev MCP

MCP (Model Context Protocol) servers for Dart/Flutter development.

## Features

This package provides the following MCP servers:

### 1. File Edit MCP (`packages/filesystem/bin/file_edit_mcp.dart`)
File system operations with restricted access to allowed paths:
- `list-content` - Recursively list files and directories
- `read-file` - Read a single file with line numbers
- `read-files` - Read multiple files
- `search-text` - Search for text patterns in files
- `create-directory` - Create directories
- `create-file` - Create new files
- `edit-file` - Edit existing files (overwrite, insert, or replace lines)
- `extract` - Extract lines from one file and insert into another

### 2. Git MCP (`packages/git/bin/git_mcp.dart`)
Git version control operations with SSH/GPG signing support:
- `status` - Show working tree status
- `branch-create` - Create a new branch
- `branch-list` - List all branches
- `branch-switch` - Switch to a branch
- `merge` - Merge a branch into current branch
- `add` - Stage files for commit
- `commit` - Commit staged changes (supports SSH and GPG signing)
- `stash` - Stash current changes
- `stash-list` - List all stashes
- `stash-apply` - Apply a stash
- `stash-pop` - Apply and remove a stash
- `tag-create` - Create a new tag
- `tag-list` - List all tags
- `log` - Show commit history
- `diff` - Show changes
- `signing-status` - Check SSH/GPG signing configuration

#### Monorepo support

The Git MCP auto-detects the enclosing git repository by walking upward from the `--project-dir` until a `.git` entry is found. This means you can point `--project-dir` at any sub-directory of a monorepo and git operations work transparently — no configuration is required.

Path-based access control (the `git:` list in `jhsware-code.yaml`) stays anchored at the project directory. Even though git runs from the parent repo root, you can only stage and commit files inside your project's allowed paths.

If no `.git` is found all the way up to the filesystem root, the server returns a clear error: `No git repository found. Searched for a .git directory starting at "<projectDir>" and walking up to the filesystem root without success. Run "git init" here or in a parent directory.`


### 3. Planner MCP (`packages/planner/bin/planner_mcp.dart`)
Task and step management for AI-assisted development. The planner is a **client**
that proxies every operation to a running **planner_server** over HTTPS — it
requires a server URL and a service token (or mTLS client cert) and keeps no local
database (see [Planner server connection](#planner-server-connection)). Operations:
- Task operations: `add-task`, `show-task`, `update-task`, `list-tasks`
- Step operations: `add-step`, `show-step`, `update-step`
- Memory: `show-task-memory`, `update-task-memory`
- Backlog items: `add-item`, `show-item`, `update-item`, `list-items`
- Slates: `add-slate`, `show-slate`, `update-slate`, `list-slates`
- Timeline: `log-commit`, `log-merge`, `get-timeline`, `get-audit-trail`
- Parent task pattern with sub-task references

### 4. Code Index MCP (`packages/code_index/bin/code_index_mcp.dart`)
Layered code indexing for token-efficient codebase exploration. Maintains a persistent SQLite index with five information layers (metadata → short summary → symbols → per-symbol descriptions → public API). Uses `package:analyzer` for Dart files; delegates to Haiku for LLM-generated summaries. Stale detection on every read via XXH3 hashing.
- `auto-scan` - Scan project tree and produce an indexing plan
- `auto-index` - Layer-aware indexing of a file
- `get-file` / `get-files` - Retrieve layered file data (selectable layers 0–4)
- `search` - Full-text search across names, descriptions, exports, and external symbols
- `usages` - Search external symbol usages by symbol, module, or dot-path
- `dependents` / `dependencies` - Import graph queries
- `search-annotations` - Search TODO/FIXME/HACK/NOTE/DEPRECATED annotations
- `overview` - Compact listing of all indexed files
- `stats` - Aggregate index statistics
- `diff` - Report changed/added/deleted files
- `is-allowed` - Check if a path is within allowed paths
- `prune-stores` - Report/remove orphaned stores under the data root
### 5. Dart Runner MCP (`packages/dart_runner/bin/dart_runner_mcp.dart`)
Run Dart programs with polling for long-running processes:
- `analyze` - Run `dart analyze`
- `test` - Run `dart test`
- `run` - Run `dart run`
- `format` - Run `dart format`
- `pub-get` - Run `dart pub get`
- `get_output` - Poll for process output
- `list_sessions` - List active sessions
- `cancel` - Cancel a running session

### 6. Flutter Runner MCP (`packages/flutter_runner/bin/flutter_runner_mcp.dart`)
Run Flutter programs via FVM with polling:
- `analyze` - Run `fvm flutter analyze`
- `test` - Run `fvm flutter test`
- `run` - Run `fvm flutter run`
- `build` - Run `fvm flutter build`
- `get_output` - Poll for process output
- `list_sessions` - List active sessions
- `cancel` - Cancel a running session

### 7. Fetch MCP (`packages/fetch/bin/fetch_mcp.dart`)
URL fetching with HTML to Markdown conversion:
- `fetch` - Fetch URL content with optional Markdown conversion
- `fetch-links` - Extract links from a URL
- `fetch-and-transform` - Fetch and convert HTML content

## CLI Arguments

All MCP servers share a common CLI argument format:

```bash
dart run packages/<server>/bin/<server>_mcp.dart \
  --project-dir=/path/to/project1 \
  --project-dir=/path/to/project2 \
  --planner-data-root=/path/to/data \
  --prompts-file=/path/to/prompts.yaml
```

### Common Arguments
- `--project-dir=PATH` - Path to a project directory (required, can be repeated for multi-project sessions)
- `--planner-data-root=PATH` - Root directory for the code-index data (required for code_index)
- `--prompts-file=PATH` - Path to prompts YAML file (optional)
- `--help, -h` - Show help message

### Database Path Inference
The code-index database path is automatically inferred from `--planner-data-root`:
- Code Index: `[planner-data-root]/projects/[project-dir-name]/db/code_index.db`

### Planner server connection

The `planner` server is a thin client for a separate **planner_server** and keeps
no local database. Point it at the server and authenticate with a service token
(or an mTLS client certificate):

- `--server-url=URL` - planner_server base URL (default `https://localhost:9444`)
- `--token=TOKEN` - service (bearer) token used to authenticate the MCP
- `--ca-cert=PATH` - pin the planner_server CA certificate (recommended in prod)
- `--client-cert=PATH` / `--client-key=PATH` - mTLS client certificate + key
- `--insecure` - skip TLS verification (development only)

Each flag has an env-var fallback: `PLANNER_SERVER_URL`, `PLANNER_SERVER_TOKEN`,
`PLANNER_SERVER_CA_CERT`, `PLANNER_SERVER_CLIENT_CERT`, `PLANNER_SERVER_CLIENT_KEY`,
`PLANNER_SERVER_INSECURE`.

Issue a service token on the planner_server host (printed once):

```bash
planner_server token issue --name <label> --kind mcp [--owner you@example.com]
```

### Project Configuration
Each project directory can contain a `jhsware-code.yaml` configuration file that specifies allowed paths per tool:

```yaml
filesystem:
  allowed_paths:
    - packages
    - test
    - README.md
    - pubspec.yaml
git:
  allowed_paths:
    - .
code-index:
  allowed_paths:
    - packages
```

### Tool Parameter: project_dir
All tool operations require a `project_dir` parameter that must match one of the registered `--project-dir` values. This enables multi-project sessions where each tool invocation specifies which project it operates on.

## Installation

```bash
# Clone the repository
git clone https://github.com/jhsware/dart_dev_mcp.git
cd dart_dev_mcp

# Get dependencies for all packages
cd packages/shared_libs && dart pub get && cd ../..
cd packages/planner && dart pub get && cd ../..
cd packages/code_index && dart pub get && cd ../..
cd packages/filesystem && dart pub get && cd ../..
cd packages/git && dart pub get && cd ../..
cd packages/dart_runner && dart pub get && cd ../..
cd packages/flutter_runner && dart pub get && cd ../..
```

## Usage with Claude Desktop

Use the `claude.sh` script to launch Claude with the MCP servers. The `planner`
server is a client for a separate **planner_server**, so it needs the server URL
and a service token — pass them as flags or via environment variables:

```bash
export PLANNER_SERVER_TOKEN=...     # issued on the planner_server host

./claude.sh all \
  --project-dir=/path/to/project \
  --planner-data-root=/path/to/data \
  --server-url=https://localhost:9444
```

`--planner-data-root` is for the code-index server; the planner server reads
`--server-url` / `--planner-token` (or `PLANNER_SERVER_URL` / `PLANNER_SERVER_TOKEN`).
Run `./claude.sh --help` for CA-pinning and mTLS options.

## Security

The file system and git MCP servers only allow access to paths specified in each project's `jhsware-code.yaml` configuration file. This prevents unauthorized access to sensitive files.

All tool invocations require a valid `project_dir` parameter that must match a registered project directory, providing isolation between projects in multi-project sessions.

## Development

```bash
# Run tests for a package
dart test packages/planner
dart test packages/filesystem

# Analyze code
dart analyze packages/shared_libs
dart analyze packages/planner

# Format code
dart format packages/
```

## License

MIT