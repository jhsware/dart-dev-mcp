#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  --help      Show this help message

Arguments:
  For 'fs' server: Specify allowed paths (directories/files)
  For 'dart'/'flutter' servers: Specify project path (default: current directory)

Examples:
  # Launch with file system tools for specific directories
  $0 fs ./lib ./bin ./test ./pubspec.yaml ./README.md

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
if [ "$1" == "" ] || [ "$1" == "--help" ]; then
  echo "$__help_text__"
  exit 0
fi

SERVERS="$1"
shift

# Collect remaining arguments as paths
PATHS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --help)
      echo "$__help_text__"
      exit 0
      ;;
    *)
      PATHS+=("$1")
      shift
      ;;
  esac
done

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
    
    echo '    "dart-dev-mcp-fs": {'
    echo '      "command": "dart",'
    echo '      "args": ['
    echo '        "run",'
    echo "        \"$SCRIPT_DIR/bin/file_edit_mcp.dart\""
    
    # Add allowed paths
    if [ ${#paths[@]} -gt 0 ]; then
      for path in "${paths[@]}"; do
        # Convert to absolute path
        abs_path="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")" 2>/dev/null || abs_path="$path"
        echo "        ,\"$abs_path\""
      done
    else
      # Default paths if none specified
      echo '        ,"./lib"'
      echo '        ,"./bin"'
      echo '        ,"./test"'
      echo '        ,"./pubspec.yaml"'
      echo '        ,"./README.md"'
    fi
    
    echo '      ]'
    echo '    }'
  fi
  
  # Convert to MD Server
  if [[ "$servers" == *"convert"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-convert": {'
    echo '      "command": "dart",'
    echo '      "args": ['
    echo '        "run",'
    echo "        \"$SCRIPT_DIR/bin/convert_to_md_mcp.dart\""
    echo '      ]'
    echo '    }'
  fi
  
  # Fetch Server
  if [[ "$servers" == *"fetch"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-fetch": {'
    echo '      "command": "dart",'
    echo '      "args": ['
    echo '        "run",'
    echo "        \"$SCRIPT_DIR/bin/fetch_mcp.dart\""
    echo '      ]'
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
    echo '      "command": "dart",'
    echo '      "args": ['
    echo '        "run",'
    echo "        \"$SCRIPT_DIR/bin/dart_runner_mcp.dart\","
    echo "        \"$abs_project_path\""
    echo '      ]'
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
    echo '      "command": "dart",'
    echo '      "args": ['
    echo '        "run",'
    echo "        \"$SCRIPT_DIR/bin/flutter_runner_mcp.dart\","
    echo "        \"$abs_project_path\""
    echo '      ]'
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
    echo '      "command": "dart",'
    echo '      "args": ['
    echo '        "run",'
    echo "        \"$SCRIPT_DIR/bin/git_mcp.dart\","
    echo "        \"$abs_project_path\""
    echo '      ]'
    echo '    }'
  fi
  
  echo '  }'
  echo '}'
}

# Generate and write config
echo "Configuring Claude Desktop with MCP servers: $SERVERS"
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
