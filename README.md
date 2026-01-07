# Dart Dev MCP

MCP (Model Context Protocol) servers for Dart/Flutter development.

## Features

This package provides the following MCP servers:

### 1. File Edit MCP (`bin/file_edit_mcp.dart`)
File system operations with restricted access to allowed paths:
- `list-content` - Recursively list files and directories
- `read-file` - Read a single file with line numbers
- `read-files` - Read multiple files
- `search-text` - Search for text patterns in files
- `create-directory` - Create directories
- `create-file` - Create new files
- `edit-file` - Edit existing files (overwrite, insert, or replace lines)

### 2. Convert to MD MCP (`bin/convert_to_md_mcp.dart`)
HTML to Markdown conversion:
- `convert` - Convert HTML content to Markdown
- `convert-url` - Fetch URL and convert to Markdown
- `extract-text` - Extract plain text from HTML
- `extract-links` - Extract all links from HTML

### 3. Fetch MCP (`bin/fetch_mcp.dart`)
URL fetching with robots.txt support:
- `fetch` - Fetch URL content with optional Markdown conversion
- `fetch-links` - Extract links from a URL

### 4. Dart Runner MCP (`bin/dart_runner_mcp.dart`)
Run Dart programs with polling for long-running processes:
- `analyze` - Run `dart analyze`
- `test` - Run `dart test`
- `run` - Run `dart run`
- `get_output` - Poll for process output
- `list_sessions` - List active sessions
- `cancel` - Cancel a running session

### 5. Flutter Runner MCP (`bin/flutter_runner_mcp.dart`)
Run Flutter programs via FVM with polling:
- `analyze` - Run `fvm flutter analyze`
- `test` - Run `fvm flutter test`
- `run` - Run `fvm flutter run`
- `build` - Run `fvm flutter build`
- `get_output` - Poll for process output
- `list_sessions` - List active sessions
- `cancel` - Cancel a running session

### 6. Git MCP (`bin/git_mcp.dart`)
Git version control operations:
- `status` - Show working tree status
- `branch-create` - Create a new branch
- `branch-list` - List all branches
- `branch-switch` - Switch to a branch
- `merge` - Merge a branch into current branch
- `add` - Stage files for commit
- `commit` - Commit staged changes
- `stash` - Stash current changes
- `stash-list` - List all stashes
- `stash-apply` - Apply a stash
- `stash-pop` - Apply and remove a stash
- `tag-create` - Create a new tag
- `tag-list` - List all tags
- `log` - Show commit history
- `diff` - Show changes

## Installation

```bash
# Clone the repository
git clone https://github.com/jhsware/dart_dev_mcp.git
cd dart_dev_mcp

# Get dependencies
dart pub get

# Compile the binaries
dart compile exe bin/file_edit_mcp.dart -o bin/file_edit_mcp
dart compile exe bin/convert_to_md_mcp.dart -o bin/convert_to_md_mcp
dart compile exe bin/fetch_mcp.dart -o bin/fetch_mcp
dart compile exe bin/dart_runner_mcp.dart -o bin/dart_runner_mcp
dart compile exe bin/flutter_runner_mcp.dart -o bin/flutter_runner_mcp
dart compile exe bin/git_mcp.dart -o bin/git_mcp
```

## Usage with Claude Desktop

Use the `claude.sh` script to launch Claude with the MCP servers:

```bash
# Launch with file editing capabilities
./claude.sh fs /path/to/allowed/dir1 /path/to/allowed/dir2

# Launch with fetch capabilities
./claude.sh fetch

# Launch with convert-to-md capabilities
./claude.sh convert

# Launch with Dart runner
./claude.sh dart

# Launch with Flutter runner
./claude.sh flutter

# Launch with Git capabilities
./claude.sh git

# Launch with multiple servers
./claude.sh fs,fetch,dart /path/to/project
```

## Security

The file system MCP server only allows access to directories specified as command-line arguments. This prevents unauthorized access to sensitive files.

Allowed paths for file operations:
- `./lib` - Library source code
- `./bin` - Binary executables
- `./test` - Test files
- `./pubspec.yaml` - Package configuration
- `./README.md` - Documentation

## Development

```bash
# Run tests
dart test

# Analyze code
dart analyze

# Format code
dart format .
```

## License

MIT
