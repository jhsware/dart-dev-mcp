#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default to production mode (installed binaries)
DEV_MODE=false
PROJECT_DIR=""

# Default allowed paths for fs and git operations
DEFAULT_ALLOWED_PATHS=(
  "./lib"
  "./bin"
  "./test"
  "./pubspec.yaml"
  "./README.md"
  "./CHANGELOG.md"
  "./.env.in"
  "./.gitignore"
  "./.github"
  "./macos"
  "git:./pubspec.lock"
)

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
  nix-infra-dev Develop packages for nix-infra
  nix-infra-machine Perform SysOps on a nix-infra machine fleet
  git         Git version control (branch, merge, commit, stash, tag)
  planner     Task and step management with SQLite storage
  all         Enable all servers

Options:
  --help              Show this help message
  --development       Use dart run with source files (for development)
  --project-dir=PATH  Working directory for the project (default: current directory)

Arguments:
  allowed_paths   Paths that fs and git servers can access (relative to project-dir)
                  Default: ${DEFAULT_ALLOWED_PATHS[*]}

Path Prefixes:
  git:<path>      Path is only passed to git server (not file editing)
                  Example: git:./docs - allows git staging of docs but not editing

SSH Signing:
  For SSH commit signing to work with passphrase-protected keys, make sure
  your key is loaded in ssh-agent BEFORE running this script:
    ssh-add ~/.ssh/id_rsa
  
  On macOS, to persist across reboots:
    ssh-add --apple-use-keychain ~/.ssh/id_rsa

Examples:
  # Launch with file system tools (using installed binaries)
  $0 fs ./lib ./bin ./test ./pubspec.yaml ./README.md

  # Launch in development mode (using dart run)
  $0 --development fs ./lib ./bin ./test

  # Launch with a specific project directory
  $0 --project-dir=/path/to/project all

  # Launch with fetch and convert tools
  $0 fetch,convert

  # Launch with Dart runner for current project
  $0 dart

  # Launch with Git tools for current project
  $0 git

  # Launch with all tools
  $0 all ./lib ./bin ./test

  # Launch with multiple servers
  $0 fs,dart,fetch ./lib ./bin ./test

  # Allow editing lib/bin/test but only git staging for docs
  $0 all ./lib ./bin ./test git:./docs git:./scripts
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
    --project-dir=*)
      PROJECT_DIR="${1#*=}"
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

# Use default paths if none specified
if [ ${#PATHS[@]} -eq 0 ]; then
  PATHS=("${DEFAULT_ALLOWED_PATHS[@]}")
fi

# Use current directory if project dir not specified
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(pwd)"
fi

# Convert to absolute path
if [[ "$PROJECT_DIR" != /* ]]; then
  PROJECT_DIR="$(cd "$(pwd)" && realpath -m "$PROJECT_DIR")"
fi

# Verify project directory exists
if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: Project directory does not exist: $PROJECT_DIR" >&2
  exit 1
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

# Find SSH agent socket
find_ssh_agent_socket() {
  # 1. Check SSH_AUTH_SOCK environment variable
  if [ -n "$SSH_AUTH_SOCK" ] && [ -e "$SSH_AUTH_SOCK" ]; then
    echo "$SSH_AUTH_SOCK"
    return
  fi
  
  # 2. macOS: Try launchctl
  if [ "$(uname -s)" = "Darwin" ]; then
    local launchd_sock
    launchd_sock=$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)
    if [ -n "$launchd_sock" ] && [ -e "$launchd_sock" ]; then
      echo "$launchd_sock"
      return
    fi
  fi
  
  # 3. Linux: Check common locations
  if [ "$(uname -s)" = "Linux" ]; then
    local uid="${UID:-$(id -u)}"
    local common_paths=(
      "/run/user/$uid/ssh-agent.socket"
      "/run/user/$uid/keyring/ssh"
    )
    for sock in "${common_paths[@]}"; do
      if [ -e "$sock" ]; then
        echo "$sock"
        return
      fi
    done
  fi
  
  echo ""
}

# Check if SSH agent has identities
check_ssh_agent_identities() {
  local sock="$1"
  if [ -z "$sock" ]; then
    return 1
  fi
  
  SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1
  return $?
}

# Convert paths to absolute paths relative to a base directory
# Usage: get_absolute_paths <base_dir> <paths...>
get_absolute_paths() {
  local base_dir="$1"
  shift
  local paths=("$@")
  local abs_paths=()
  
  for path in "${paths[@]}"; do
    if [[ "$path" = /* ]]; then
      # Already absolute
      abs_paths+=("$path")
    else
      # Make absolute relative to base_dir
      abs_paths+=("$(cd "$base_dir" 2>/dev/null && realpath -m "$path" 2>/dev/null || echo "$base_dir/$path")")
    fi
  done
  
  echo "${abs_paths[@]}"
}

# Filter paths by prefix and return clean paths
# Usage: filter_paths <prefix> <paths...>
# prefix: "git:" for git-only paths, "" for regular paths
# Returns paths that match (with prefix removed) or don't have any prefix
filter_paths() {
  local filter_prefix="$1"
  shift
  local paths=("$@")
  local filtered=()
  
  for path in "${paths[@]}"; do
    if [[ "$filter_prefix" == "git:" ]]; then
      # Return git-only paths (strip prefix)
      if [[ "$path" == git:* ]]; then
        filtered+=("${path#git:}")
      fi
    else
      # Return regular paths (no prefix)
      if [[ "$path" != git:* ]]; then
        filtered+=("$path")
      fi
    fi
  done
  
  echo "${filtered[@]}"
}

# Output server command configuration based on mode
# Usage: output_server_cmd <binary_name> <dart_source> [env_json] [args...]
# If env_json is "null", no env block is added
output_server_cmd() {
  local binary_name="$1"
  local dart_source="$2"
  local env_json="$3"
  shift 3
  local extra_args=("$@")

  local binary_src_path=""
  if [ -f "$HOME/dev/nix-infra/bin/${dart_source}" ]; then
    binary_src_path="$HOME/dev/nix-infra/bin/${dart_source}"
  elif [ -f "$SCRIPT_DIR/bin/${dart_source}" ]; then
    binary_src_path="$SCRIPT_DIR/bin/${dart_source}"
  fi
  
  if [ "$DEV_MODE" = true ]; then
    # Development mode: use dart run
    echo '      "command": "dart",'
    echo '      "args": ['
    echo '        "run",'
    echo "        \"$binary_src_path\""
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
  
  # Add env block if provided
  if [ "$env_json" != "null" ] && [ -n "$env_json" ]; then
    echo "      ,$env_json"
  fi
}

# Build MCP servers configuration
build_mcp_config() {
  local servers="$1"
  local ssh_agent_socket="$2"
  shift 2
  local paths=("$@")
  
  # Use PROJECT_DIR as the project path
  local project_path="$PROJECT_DIR"
  
  # Separate regular paths from git-only paths
  local regular_paths=($(filter_paths "" "${paths[@]}"))
  local git_only_paths=($(filter_paths "git:" "${paths[@]}"))
  
  # Convert to absolute paths
  local abs_regular_paths=($(get_absolute_paths "$project_path" "${regular_paths[@]}"))
  local abs_git_only_paths=($(get_absolute_paths "$project_path" "${git_only_paths[@]}"))
  
  # Git gets both regular and git-only paths
  local abs_git_paths=("${abs_regular_paths[@]}" "${abs_git_only_paths[@]}")
  
  # Build env JSON for git server (includes SSH_AUTH_SOCK)
  local git_env="null"
  if [ -n "$ssh_agent_socket" ]; then
    git_env="\"env\": { \"SSH_AUTH_SOCK\": \"$ssh_agent_socket\" }"
  fi
  
  # Start JSON
  echo '{'
  echo '  "mcpServers": {'
  
  local first=true
  
  # Check for 'all' keyword
  if [[ "$servers" == *"all"* ]]; then
    servers="fs,convert,fetch,dart,flutter,git,planner"
  fi
  
  # File System Server - uses --project-dir and regular paths only (not git-only)
  if [[ "$servers" == *"fs"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-fs": {'
    output_server_cmd "file-edit-mcp" "file_edit_mcp.dart" "null" "--project-dir=$project_path" "${abs_regular_paths[@]}"
    echo '    }'
  fi
  
  # Convert to MD Server
  if [[ "$servers" == *"convert"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-convert": {'
    output_server_cmd "convert-to-md-mcp" "convert_to_md_mcp.dart" "null"
    echo '    }'
  fi
  
  # Fetch Server
  if [[ "$servers" == *"fetch"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-fetch": {'
    output_server_cmd "fetch-mcp" "fetch_mcp.dart" "null"
    echo '    }'
  fi
  
  # Dart Runner Server - uses --project-dir
  if [[ "$servers" == *"dart"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-dart-runner": {'
    output_server_cmd "dart-runner-mcp" "dart_runner_mcp.dart" "null" "--project-dir=$project_path"
    echo '    }'
  fi
  
  # Flutter Runner Server - uses --project-dir
  if [[ "$servers" == *"flutter"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-flutter-runner": {'
    output_server_cmd "flutter-runner-mcp" "flutter_runner_mcp.dart" "null" "--project-dir=$project_path"
    echo '    }'
  fi
  
  # Git Server - uses --project-dir AND all paths (regular + git-only) for staging
  # Also includes SSH_AUTH_SOCK for SSH signing
  if [[ "$servers" == *"git"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-git": {'
    output_server_cmd "git-mcp" "git_mcp.dart" "$git_env" "--project-dir=$project_path" "${abs_git_paths[@]}"
    echo '    }'
  fi
  
  # Planner Server - uses --project-dir for task/step management
  if [[ "$servers" == *"planner"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-planner": {'
    output_server_cmd "planner-mcp" "planner_mcp.dart" "null" "--project-dir=$project_path"
    echo '    }'
  fi

  # nix-infra-dev-mcp
  if [[ "$servers" == *"nix-infra-dev"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "nix-infra-dev-mcp": {'
    output_server_cmd "nix-infra-dev-mcp" "nix-infra-dev-mcp.dart" "null" "--project-dir=$project_path"
    echo '    }'
  fi

  # nix-infra-machine-mcp
  if [[ "$servers" == *"nix-infra-machine"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "nix-infra-machine-mcp": {'
    output_server_cmd "nix-infra-machine-mcp" "nix-infra-machine-mcp.dart" "null" "--project-dir=$project_path"
    echo '    }'
  fi

  # nix-infra-cluster-mcp
  if [[ "$servers" == *"nix-infra-cluster"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "nix-infra-cluster-mcp": {'
    output_server_cmd "nix-infra-cluster-mcp" "nix-infra-cluster-mcp.dart" "null" "--project-dir=$project_path"
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
echo "Project directory: $PROJECT_DIR"

# Show path summary
regular_paths=($(filter_paths "" "${PATHS[@]}"))
git_only_paths=($(filter_paths "git:" "${PATHS[@]}"))

if [ ${#regular_paths[@]} -gt 0 ]; then
  echo "Allowed paths (fs + git): ${regular_paths[*]}"
fi
if [ ${#git_only_paths[@]} -gt 0 ]; then
  echo "Allowed paths (git only): ${git_only_paths[*]}"
fi

# Check SSH agent for git signing
SSH_AGENT_SOCKET=""
if [[ "$SERVERS" == *"git"* ]] || [[ "$SERVERS" == *"all"* ]]; then
  SSH_AGENT_SOCKET=$(find_ssh_agent_socket)
  
  if [ -n "$SSH_AGENT_SOCKET" ]; then
    echo ""
    echo "SSH Agent: $SSH_AGENT_SOCKET"
    if check_ssh_agent_identities "$SSH_AGENT_SOCKET"; then
      echo "SSH Keys: ✓ Keys loaded in agent"
    else
      echo "SSH Keys: ⚠ No keys loaded in agent"
      echo ""
      echo "  For SSH commit signing, add your key first:"
      echo "    ssh-add ~/.ssh/id_rsa"
      echo ""
      echo "  On macOS, to persist across reboots:"
      echo "    ssh-add --apple-use-keychain ~/.ssh/id_rsa"
    fi
  else
    echo ""
    echo "SSH Agent: ⚠ Not found"
    echo ""
    echo "  SSH commit signing will not work without ssh-agent."
    echo "  Start ssh-agent and add your key:"
    echo "    eval \$(ssh-agent)"
    echo "    ssh-add ~/.ssh/id_rsa"
    echo ""
    echo "  Or use sign=\"none\" for unsigned commits."
  fi
fi

build_mcp_config "$SERVERS" "$SSH_AGENT_SOCKET" "${PATHS[@]}" > "$PATH_TO_CLAUDE/claude_desktop_config.json"

echo ""
echo "Configuration written to: $PATH_TO_CLAUDE/claude_desktop_config.json"
echo ""
cat "$PATH_TO_CLAUDE/claude_desktop_config.json"
echo ""

# Run Claude
echo "Starting Claude..."
"$CLAUDE_BIN" 2>&1 &

echo ""
echo "Claude started. Restoring claude_desktop_config.json to previous state"
if [ -f "$PATH_TO_CLAUDE/claude_desktop_config.json.dart-dev-mcp.bak" ]; then
  cp -f "$PATH_TO_CLAUDE/claude_desktop_config.json.dart-dev-mcp.bak" "$PATH_TO_CLAUDE/claude_desktop_config.json"
else
  rm -f "$PATH_TO_CLAUDE/claude_desktop_config.json"
fi
