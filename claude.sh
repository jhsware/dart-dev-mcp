#!/usr/bin/env bash
set -e

# Enable job control (required for 'fg' in scripts)
set -m

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLANNER_DATA_ROOT=${SSH_KEY:-"$HOME/Library/Application Support/se.urbantalk.planner-app"}

# planner_remote -> planner_server connection.
# Values may come from the environment or the matching CLI flags below.
PLANNER_SERVER_URL=${PLANNER_SERVER_URL:-"https://localhost:9444"}
PLANNER_SERVER_TOKEN=${PLANNER_SERVER_TOKEN:-""}
PLANNER_SERVER_CA_CERT=${PLANNER_SERVER_CA_CERT:-""}
PLANNER_SERVER_CLIENT_CERT=${PLANNER_SERVER_CLIENT_CERT:-""}
PLANNER_SERVER_CLIENT_KEY=${PLANNER_SERVER_CLIENT_KEY:-""}

SERVERS=""

# Default to production mode (installed binaries)
DEV_MODE=false
PROJECT_DIRS=()

__help_text__=$(cat <<EOF
Dart Dev MCP - Claude Desktop Launcher
=======================================

Usage: $0 <servers> [options]

Servers (comma-separated):
  fs          File system editing tools
  fetch       URL fetching tools
  dart        Dart runner (analyze, test, run)
  flutter     Flutter runner via FVM (analyze, test, run, build)
  nix-infra-dev Develop packages for nix-infra
  nix-infra-machine Perform SysOps on a nix-infra machine fleet
  git         Git version control (branch, merge, commit, stash, tag)
  planner     Task/step management (remote: proxies to planner_server over HTTPS)
  code-index  Code file index for efficient search
  apple-mail  Apple Mail read-only operations (list, search, export)
  all         Enable all servers

Options:
  --help                    Show this help message
  --development             Use dart run with source files (for development)
                            (planner: disables mTLS, skips server-cert verification)
  --project-dir=PATH        Project directory (can be specified multiple times)
  --planner-data-root=PATH  Root directory for the code-index database
                            DB path inferred as: [root]/projects/[dir-name]/db/planner.db

planner_server connection (for the 'planner' server):
  --server-url=URL          planner_server base URL (default: https://localhost:9444)
  --planner-token=TOKEN     Service (bearer) token used to authenticate the MCP
  --ca-cert=PATH            Pin the planner_server CA certificate (recommended in prod)
  --client-cert=PATH        mTLS client certificate (hardened mode only)
  --client-key=PATH         mTLS client key (hardened mode only)

  Env fallbacks: PLANNER_SERVER_URL, PLANNER_SERVER_TOKEN, PLANNER_SERVER_CA_CERT,
  PLANNER_SERVER_CLIENT_CERT, PLANNER_SERVER_CLIENT_KEY.

  Issue a service token on the planner_server host (printed once):
    planner_server token issue --name <label> --kind mcp [--owner you@example.com]

SSH Signing:
  For SSH commit signing to work with passphrase-protected keys, make sure
  your key is loaded in ssh-agent BEFORE running this script:
    ssh-add ~/.ssh/id_rsa
  
  On macOS, to persist across reboots:
    ssh-add --apple-use-keychain ~/.ssh/id_rsa

Allowed paths:
  File system and git allowed paths are now configured per-project via
  jhsware-code.yaml in each project directory.

Examples:
  # Launch with all tools for a single project
  $0 all --project-dir=/path/to/project --planner-data-root=~/planner-data

  # Launch with multiple project directories
  $0 all --project-dir=/path/to/project1 --project-dir=/path/to/project2 --planner-data-root=~/planner-data

  # Launch in development mode
  $0 --development all --project-dir=/path/to/project --planner-data-root=~/planner-data

  # Launch with specific servers
  $0 fs,dart,git --project-dir=/path/to/project
EOF
)

# Parse arguments

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
      PROJECT_DIRS+=("${1#*=}")
      shift
      ;;
    --planner-data-root=*)
      PLANNER_DATA_ROOT="${1#*=}"
      shift
      ;;
    --server-url=*)
      PLANNER_SERVER_URL="${1#*=}"
      shift
      ;;
    --planner-token=*)
      PLANNER_SERVER_TOKEN="${1#*=}"
      shift
      ;;
    --ca-cert=*)
      PLANNER_SERVER_CA_CERT="${1#*=}"
      shift
      ;;
    --client-cert=*)
      PLANNER_SERVER_CLIENT_CERT="${1#*=}"
      shift
      ;;
    --client-key=*)
      PLANNER_SERVER_CLIENT_KEY="${1#*=}"
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
        echo "Unknown positional argument: $1" >&2
        echo "Allowed paths are now configured via jhsware-code.yaml in each project directory." >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$SERVERS" ]; then
  echo "$__help_text__"
  exit 0
fi

if [ ${#PROJECT_DIRS[@]} -eq 0 ]; then
  echo "Error: at least one --project-dir is required" >&2
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

# Output server command configuration based on mode
# Usage: output_server_cmd <binary_name> <dart_source> [env_json] [args...]
# If env_json is "null", no env block is added
output_server_cmd() {
  local binary_name="$1"
  local dart_source="$2"
  local env_json="$3"
  shift 3
  local extra_args=("$@")

  # Look up package directory for this binary
  local package_dir=""
  case "$dart_source" in
    file_edit_mcp.dart) package_dir="filesystem" ;;
    fetch_mcp.dart) package_dir="fetch" ;;
    dart_runner_mcp.dart) package_dir="dart_runner" ;;
    flutter_runner_mcp.dart) package_dir="flutter_runner" ;;
    git_mcp.dart) package_dir="git" ;;
    planner_mcp.dart) package_dir="planner" ;;
    planner_remote_mcp.dart) package_dir="planner_remote" ;;
    code_index_mcp.dart) package_dir="code_index" ;;
    apple_mail_mcp.dart) package_dir="apple_mail_mcp" ;;
  esac

  local binary_src_path=""
  if [ -f "$HOME/dev/nix-infra/bin/${dart_source}" ]; then
    binary_src_path="$HOME/dev/nix-infra/bin/${dart_source}"
  elif [ -n "$package_dir" ] && [ -f "$SCRIPT_DIR/packages/$package_dir/bin/${dart_source}" ]; then
    binary_src_path="$SCRIPT_DIR/packages/$package_dir/bin/${dart_source}"
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

# Build --project-dir args array
build_project_dir_args() {
  local args=()
  for dir in "${PROJECT_DIRS[@]}"; do
    args+=("--project-dir=$dir")
  done
  echo "${args[@]}"
}

# Build MCP servers configuration
build_mcp_config() {
  local servers="$1"
  local ssh_agent_socket="$2"
  shift 2
  
  # Build env JSON for git server (includes SSH_AUTH_SOCK)
  local git_env="null"
  if [ -n "$ssh_agent_socket" ]; then
    git_env="\"env\": { \"SSH_AUTH_SOCK\": \"$ssh_agent_socket\" }"
  fi

  # Build project-dir args
  local project_dir_args=()
  for dir in "${PROJECT_DIRS[@]}"; do
    project_dir_args+=("--project-dir=$dir")
  done
  
  # Start JSON
  echo '{'
  echo '  "mcpServers": {'
  
  local first=true
  
  # Check for 'all' keyword
  if [[ "$servers" == *"all"* ]]; then
    servers="fs,fetch,dart,flutter,git,planner,code-index,apple-mail"
  fi
  
  # File System Server
  if [[ "$servers" == *"fs"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-fs": {'
    output_server_cmd "file-edit-mcp" "file_edit_mcp.dart" "null" "${project_dir_args[@]}"
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
  
  # Dart Runner Server
  if [[ "$servers" == *"dart"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-dart-runner": {'
    output_server_cmd "dart-runner-mcp" "dart_runner_mcp.dart" "null" "${project_dir_args[@]}"
    echo '    }'
  fi
  
  # Flutter Runner Server
  if [[ "$servers" == *"flutter"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-flutter-runner": {'
    output_server_cmd "flutter-runner-mcp" "flutter_runner_mcp.dart" "null" "${project_dir_args[@]}"
    echo '    }'
  fi
  
  # Git Server (includes SSH_AUTH_SOCK for SSH signing)
  if [[ "$servers" == *"git"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "dart-dev-mcp-git": {'
    output_server_cmd "git-mcp" "git_mcp.dart" "$git_env" "${project_dir_args[@]}"
    echo '    }'
  fi
  
  # Planner Server (remote — proxies to planner_server over HTTPS)
  if [[ "$servers" == *"planner"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false

    # Assemble planner_remote args: server URL first, then optional TLS material.
    local planner_args=("--server-url=$PLANNER_SERVER_URL")
    if [ -n "$PLANNER_SERVER_CA_CERT" ]; then
      planner_args+=("--ca-cert=$PLANNER_SERVER_CA_CERT")
    fi
    # mTLS only when BOTH the client cert and key are provided.
    if [ -n "$PLANNER_SERVER_CLIENT_CERT" ] && [ -n "$PLANNER_SERVER_CLIENT_KEY" ]; then
      planner_args+=("--client-cert=$PLANNER_SERVER_CLIENT_CERT")
      planner_args+=("--client-key=$PLANNER_SERVER_CLIENT_KEY")
    fi
    # Development mode: no mTLS, and skip verification of the dev server cert.
    if [ "$DEV_MODE" = true ]; then
      planner_args+=("--insecure")
    fi
    planner_args+=("${project_dir_args[@]}")

    # Pass the service token via env so it is not embedded in the args array.
    local planner_env="null"
    if [ -n "$PLANNER_SERVER_TOKEN" ]; then
      planner_env="\"env\": { \"PLANNER_SERVER_TOKEN\": \"$PLANNER_SERVER_TOKEN\" }"
    fi

    echo '    "dart-dev-mcp-planner": {'
    output_server_cmd "planner-remote-mcp" "planner_remote_mcp.dart" "$planner_env" "${planner_args[@]}"
    echo '    }'
  fi

  # Code Index Server
  if [[ "$servers" == *"code-index"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false

    echo '    "dart-dev-mcp-code-index": {'
    output_server_cmd "code-index-mcp" "code_index_mcp.dart" "null" "--planner-data-root=$PLANNER_DATA_ROOT" "${project_dir_args[@]}"
    echo '    }'
  fi

  # Apple Mail MCP Server - standalone, no project-dir needed
  if [[ "$servers" == *"apple-mail"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false

    echo '    "apple-mail-mcp": {'
    output_server_cmd "apple-mail-mcp" "apple_mail_mcp.dart" "null"
    echo '    }'
  fi

  # nix-infra-dev-mcp
  if [[ "$servers" == *"nix-infra-dev"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "nix-infra-dev-mcp": {'
    output_server_cmd "nix-infra-dev-mcp" "nix_infra_dev_mcp.dart" "null" "${project_dir_args[@]}"
    echo '    }'
  fi

  # nix-infra-machine-mcp
  if [[ "$servers" == *"nix-infra-machine"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "nix-infra-machine-mcp": {'
    output_server_cmd "nix-infra-machine-mcp" "nix_infra_machine_mcp.dart" "null" "${project_dir_args[@]}"
    echo '    }'
  fi

  # nix-infra-cluster-mcp
  if [[ "$servers" == *"nix-infra-cluster"* ]]; then
    if [ "$first" != true ]; then echo ','; fi
    first=false
    
    echo '    "nix-infra-cluster-mcp": {'
    output_server_cmd "nix-infra-cluster-mcp" "nix_infra_cluster_mcp.dart" "null" "${project_dir_args[@]}"
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
echo "Project directories: ${PROJECT_DIRS[*]}"
if [ -n "$PLANNER_DATA_ROOT" ]; then
  echo "Planner data root: $PLANNER_DATA_ROOT"
fi
if [[ "$SERVERS" == *"planner"* ]] || [[ "$SERVERS" == *"all"* ]]; then
  echo "Planner server URL: $PLANNER_SERVER_URL"
  if [ "$DEV_MODE" = true ]; then
    echo "Planner TLS: development mode (mTLS off, server-cert verification skipped)"
  fi
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

# code-index still stores its index locally and needs a data root.
if [[ "$SERVERS" == *"code-index"* ]] || [[ "$SERVERS" == *"all"* ]]; then
  if [ -z "$PLANNER_DATA_ROOT" ]; then
    echo ""
    echo "Warning: --planner-data-root is required for the code-index server" >&2
    echo "  Example: --planner-data-root=\"\$HOME/Library/Application Support/se.urbantalk.planner-app\"" >&2
    exit 1
  fi
fi

# planner (remote) authenticates to planner_server with a service token or mTLS cert.
if [[ "$SERVERS" == *"planner"* ]] || [[ "$SERVERS" == *"all"* ]]; then
  if [ -z "$PLANNER_SERVER_TOKEN" ] && { [ -z "$PLANNER_SERVER_CLIENT_CERT" ] || [ -z "$PLANNER_SERVER_CLIENT_KEY" ]; }; then
    echo ""
    echo "Warning: planner (remote) has no credentials configured." >&2
    echo "  Provide a service token:  export PLANNER_SERVER_TOKEN=...   (or --planner-token=...)" >&2
    echo "  ...or an mTLS client cert: export PLANNER_SERVER_CLIENT_CERT=... PLANNER_SERVER_CLIENT_KEY=..." >&2
    echo "  Issue a token on the planner_server host with:" >&2
    echo "    planner_server token issue --name <label> --kind mcp [--owner you@example.com]" >&2
  fi
fi

build_mcp_config "$SERVERS" "$SSH_AGENT_SOCKET" > "$PATH_TO_CLAUDE/claude_desktop_config.json"

echo ""
echo "Configuration written to: $PATH_TO_CLAUDE/claude_desktop_config.json"
echo ""
# Print the generated config, redacting the planner service token.
sed -E 's/("PLANNER_SERVER_TOKEN": ")[^"]*"/\1***redacted***"/' "$PATH_TO_CLAUDE/claude_desktop_config.json"
echo ""

# Run Claude
echo "Starting Claude..."
"$CLAUDE_BIN" 2>/dev/null &

sleep 10

echo ""
echo "Claude started. Restoring claude_desktop_config.json to previous state"
if [ -f "$PATH_TO_CLAUDE/claude_desktop_config.json.dart-dev-mcp.bak" ]; then
  cp -f "$PATH_TO_CLAUDE/claude_desktop_config.json.dart-dev-mcp.bak" "$PATH_TO_CLAUDE/claude_desktop_config.json"
else
  rm -f "$PATH_TO_CLAUDE/claude_desktop_config.json"
fi

echo ""
echo "Previous configuration restored at: '$PATH_TO_CLAUDE/claude_desktop_config.json'"
echo ""
# cat "$PATH_TO_CLAUDE/claude_desktop_config.json"

# Bring Claude to the foreground
# Using '|| true' prevents 'set -e' from killing the script 
# if the process finishes right as you foreground it.
fg %1 || true
