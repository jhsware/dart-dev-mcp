#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# All MCP server binaries
BINARIES="file_edit_mcp convert_to_md_mcp fetch_mcp dart_runner_mcp flutter_runner_mcp git_mcp"

show_help() {
  cat <<EOF
Dart Dev MCP - Build Script
============================

Usage: $0 <command> [options]

Commands:
  build-macos     Compile all MCP servers for macOS
  build-linux     Compile all MCP servers for Linux
  build           Compile for current platform
  test            Run all tests
  clean           Remove compiled binaries and .dill files

Options:
  --help          Show this help message

Examples:
  $0 build          # Build for current platform
  $0 build-macos    # Build for macOS
  $0 build-linux    # Build for Linux
  $0 test           # Run tests
  $0 clean          # Clean build artifacts
EOF
}

do_test() {
  echo "Running tests..."
  dart pub get --enforce-lockfile
  dart analyze
  dart test
  echo "All tests passed!"
}

do_build() {
  local target_os="$1"
  local os_flag=""
  local output_dir="bin"
  
  if [ -n "$target_os" ]; then
    os_flag="--target-os $target_os"
    output_dir="bin/$target_os"
    mkdir -p "$output_dir"
  fi

  echo "Installing dependencies..."
  dart pub get --enforce-lockfile

  echo "Compiling MCP servers${target_os:+ for $target_os}..."
  
  for binary in $BINARIES; do
    local output_name="${binary//_/-}"  # Convert underscores to hyphens for binary name
    echo "  Compiling $binary..."
    dart compile exe --verbosity error $os_flag \
      -o "$output_dir/$output_name" \
      "bin/${binary}.dart"
  done

  echo ""
  echo "Build complete! Binaries are in $output_dir/"
  ls -la "$output_dir/" | grep -E "^-"
}

do_clean() {
  echo "Cleaning build artifacts..."
  
  # Remove compiled binaries (files without .dart extension in bin/)
  for binary in $BINARIES; do
    local output_name="${binary//_/-}"
    [ -f "bin/$output_name" ] && rm -f "bin/$output_name" && echo "  Removed bin/$output_name"
  done
  
  # Remove platform-specific builds
  [ -d "bin/macos" ] && rm -rf "bin/macos" && echo "  Removed bin/macos/"
  [ -d "bin/linux" ] && rm -rf "bin/linux" && echo "  Removed bin/linux/"
  
  # Remove .dill files (test compilation cache)
  find bin -name "*.dill" -delete 2>/dev/null && echo "  Removed .dill files"
  
  echo "Clean complete!"
}

# Check for --help flag first
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      show_help
      exit 0
      ;;
  esac
done

# Parse command
CMD="${1:-}"

if [ -z "$CMD" ]; then
  echo "Error: No command specified" >&2
  echo ""
  show_help
  exit 1
fi

case "$CMD" in
  build-macos)
    do_build "macos"
    ;;
  build-linux)
    do_build "linux"
    ;;
  build)
    do_build ""
    ;;
  test)
    do_test
    ;;
  clean)
    do_clean
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    echo ""
    show_help
    exit 1
    ;;
esac
