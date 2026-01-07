#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default to production mode (installed binaries)
DEV_MODE=false

__help_text__=$(cat <<EOF
Dart Dev MCP - Claude Desktop Launcher
=======================================

Usage: $0 <servers> [options] [allowed_paths...]

Servers (comma-separated):
  fs          File system editing tools
  convert     HTML to Markdown conversion
  fetch       URL fetching tools
  dart        Dart runner (analyze, test, run)
  flutter     Flutter runner via FVM (analyze, test, run, build)
  git         Git version control (branch, merge, commit, stash, tag)
  all         Enable all servers

Options:
  --help          Show this help message
  --development   Use dart run with source files (for development)

Arguments:
  For 'fs' server: Specify allowed paths (directories/files)
  For 'dart'/'flutter'/'git' servers: Specify project path (default: current directory)

Examples:
  # Launch with file system tools (using installed binaries)
  $0 fs ./lib ./bin ./test ./pubspec.yaml ./README.md

  # Launch in development mode (using dart run)
  $0 --development fs ./lib ./bin ./test

  # Launch with fetch and convert tools
  $0 fetch,convert

  # Launch with Dart runner for current project
  $0 dart

  # Launch with Flutter runner for a specific project
  $0 flutter /path/to/flutter/project

  # Launch with Git tools for current project
  $0 git

  # Launch with all tools
  $0 all ./lib ./bin ./test

  # Launch with multiple servers
  $0 fs,dart,fetch ./lib ./bin ./test
EOF
)

# Parse arguments
SERVERS=""
PATHS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      echo "$__help_text__"
      exit 0
      ;;
    --development|--dev)
      DEV_MODE=true
      shift
      ;;
    --*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [ -z "$SERVERS" ]; then
        SERVERS="$1"
      else
        PATHS+=("$1")
      fi
      shift
      ;;
  esac
done

if [ -z "$SERVERS" ]; then
  echo "$__help_text__"
  exit 0
fi

# Detect OS and set paths accordingly
case "$(uname -s)" in
  Darwin)
    PATH_TO_CLAUDE="$HOME/Library/Application Support/Claude"
    CLAUDE_BIN="/Applications/Claude.app/Contents/MacOS/Claude"
    ;;
  Linux)
    PATH_TO_CLAUDE="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
    CLAUDE_BIN="claude"
    ;;
  *)
    echo "Unsupported operating system: $(uname -s)" >&2
    exit 1
    ;;
esac

if [ ! -d "$PATH_TO_CLAUDE" ]; then
  echo "Claude Application Support directory not found at: $PATH_TO_CLAUDE" >&2
  echo "Please start the Claude app once manually and retry." >&2
  exit 1
fi

# Backup existing config
if [ -f "$PATH_TO_CLAUDE/claude_desktop_config.json" ]; then
  cp -f "$PATH_TO_CLAUDE/claude_desktop_config.json" "$PATH_TO_CLAUDE/claude_desktop_config.json.dart-dev-mcp.bak"
fi

# Output server command configuration based on mode
# Usage: output_server_cmd <binary_name> <dart_source> [args...]
output_server_cmd() {
  local binary_name="$1"
  local dart_source="$2"
  shift 2
  local extra_args=("$@")
  
  if [ "$DEV_MODE" = true ]; then
    # Development mode: use dart run
    echo '      "command": "dart",'
    echo '      "args": ['
    echo '        "run",'
    echo "        \"$SCRIPT_DIR/bin/${dart_source}\""
    for arg in "${extra_args[@]}"; do
      echo "        ,\"$arg\""
    done
    echo '      ]'
  else
    # Production mode: use installed binary (found via system PATH)
    echo "      \"command\": \"$binary_name\","
    echo '      "args": ['
    local first_arg=true
    for arg in "${extra_args[@]}"; do
      if [ "$first_arg" = true ]; then
        echo "        \"$arg\""
        first_arg=false
      else
        echo "        ,\"$arg\""
      fi
    done
    echo '      ]'
  fi
}

# Build MCP servers configuration
build_mcp_config() {
  local servers="$1"
  shift
  local paths=("$@")
  
  # Start JSON
  echo '{'
  echo '  "mcpServers": {'
  
  local first=true
  
  # Check for 'all' keyword
  if [[ "$servers" == *"all"* ]]; then
    servers="fs,convert,fetch,dart,flutter,git"
  fi
  
  # File System Server
  if [[ "$servers" == *"fs"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    # Build allowed paths array
    local fs_paths=()
    if [ ${#paths[@]} -gt 0 ]; then
      for path in "${paths[@]}"; do
        # Convert to absolute path
        abs_path="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")" 2>/dev/null || abs_path="$path"
        fs_paths+=("$abs_path")
      done
    else
      # Default paths if none specified
      fs_paths=("./lib" "./bin" "./test" "./pubspec.yaml" "./README.md" "./CHANGELOG.md" "./.env.in" "./.gitignore" "./.github")
    fi
    
    echo '    "dart-dev-mcp-fs": {'
    output_server_cmd "file-edit-mcp" "file_edit_mcp.dart" "${fs_paths[@]}"
    echo '    }'
  fi
  
  # Convert to MD Server
  if [[ "$servers" == *"convert"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-convert": {'
    output_server_cmd "convert-to-md-mcp" "convert_to_md_mcp.dart"
    echo '    }'
  fi
  
  # Fetch Server
  if [[ "$servers" == *"fetch"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-fetch": {'
    output_server_cmd "fetch-mcp" "fetch_mcp.dart"
    echo '    }'
  fi
  
  # Dart Runner Server
  if [[ "$servers" == *"dart"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    # Use first path as project path, or current directory
    local project_path="${paths[0]:-.}"
    abs_project_path="$(cd "$project_path" 2>/dev/null && pwd)" 2>/dev/null || abs_project_path="$project_path"
    
    echo '    "dart-dev-mcp-dart-runner": {'
    output_server_cmd "dart-runner-mcp" "dart_runner_mcp.dart" "$abs_project_path"
    echo '    }'
  fi
  
  # Flutter Runner Server
  if [[ "$servers" == *"flutter"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    # Use first path as project path, or current directory
    local project_path="${paths[0]:-.}"
    abs_project_path="$(cd "$project_path" 2>/dev/null && pwd)" 2>/dev/null || abs_project_path="$project_path"
    
    echo '    "dart-dev-mcp-flutter-runner": {'
    output_server_cmd "flutter-runner-mcp" "flutter_runner_mcp.dart" "$abs_project_path"
    echo '    }'
  fi
  
  # Git Server
  if [[ "$servers" == *"git"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    # Use first path as project path, or current directory
    local project_path="${paths[0]:-.}"
    abs_project_path="$(cd "$project_path" 2>/dev/null && pwd)" 2>/dev/null || abs_project_path="$project_path"
    
    echo '    "dart-dev-mcp-git": {'
    output_server_cmd "git-mcp" "git_mcp.dart" "$abs_project_path"
    echo '    }'
  fi
  
  echo '  }'
  echo '}'
}

# Generate and write config
if [ "$DEV_MODE" = true ]; then
  echo "Configuring Claude Desktop with MCP servers (DEVELOPMENT MODE): $SERVERS"
else
  echo "Configuring Claude Desktop with MCP servers: $SERVERS"
fi

build_mcp_config "$SERVERS" "${PATHS[@]}" > "$PATH_TO_CLAUDE/claude_desktop_config.json"

echo "Configuration written to: $PATH_TO_CLAUDE/claude_desktop_config.json"
echo ""
cat "$PATH_TO_CLAUDE/claude_desktop_config.json"
echo ""

# Run Claude
echo "Starting Claude..."
"$CLAUDE_BIN" 2>&1 &

echo ""
echo "Claude started. When you close Claude, run the following to restore your previous config:"
echo "  cp -f \"$PATH_TO_CLAUDE/claude_desktop_config.json.dart-dev-mcp.bak\" \"$PATH_TO_CLAUDE/claude_desktop_config.json\""
