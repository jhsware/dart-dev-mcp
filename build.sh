#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# All MCP server binaries
BINARIES="file_edit_mcp fetch_mcp dart_runner_mcp flutter_runner_mcp git_mcp planner_mcp code_index_mcp"

# Get package directory for a binary
get_package_dir() {
  case "$1" in
    file_edit_mcp) echo "filesystem" ;;
    fetch_mcp) echo "fetch" ;;
    dart_runner_mcp) echo "dart_runner" ;;
    flutter_runner_mcp) echo "flutter_runner" ;;
    git_mcp) echo "git" ;;
    planner_mcp) echo "planner" ;;
    code_index_mcp) echo "code_index" ;;
    *) echo "$1" ;;
  esac
}

show_help() {
  cat <<EOF
Dart Dev MCP - Build Script
============================

Usage: $0 <command> [options]

Commands:
  build-macos             Compile all MCP servers for macOS
  build-linux             Compile all MCP servers for Linux
  build                   Compile for current platform
  test                    Run all tests
  clean                   Remove compiled binaries and .dill files
  release-macos           Sign and notarize macOS binaries (requires --env)
  list-identities         List available code signing identities
  create-keychain-profile Create keychain profile for notarytool
  notarytool-log          Get notarization log (requires --log-id)

Options:
  --help                  Show this help message
  --env=<file>            Source environment variables from file (for release-macos)
  --log-id=<id>           Notarization log ID (for notarytool-log)

Environment variables for release-macos:
  DEV_CERTIFICATE         Developer ID Installer certificate name
  DEV_APP_CERTIFICATE     Developer ID Application certificate name
  DEV_IDENTIFIER          Bundle identifier (e.g., com.example.dart-dev-mcp)
  DEV_CREDENTIAL_PROFILE  Keychain profile name for notarytool

Examples:
  $0 build                          # Build for current platform
  $0 build-macos                    # Build for macOS
  $0 build-linux                    # Build for Linux
  $0 test                           # Run tests
  $0 clean                          # Clean build artifacts
  $0 release-macos --env=.env       # Sign and notarize with env file
  $0 list-identities                # List signing identities
  $0 notarytool-log --log-id=xyz    # Get notarization log
EOF
}

checkVar() {
  if [ -z "$1" ]; then
    echo "Missing env-var $2" >&2
    exit 1
  fi
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
      "packages/$(get_package_dir "$binary")/bin/${binary}.dart"
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
  
  # Remove installer package
  [ -d "bin/dart-dev-mcp-installer" ] && rm -rf "bin/dart-dev-mcp-installer" && echo "  Removed bin/dart-dev-mcp-installer/"
  [ -f "bin/dart-dev-mcp-installer.pkg" ] && rm -f "bin/dart-dev-mcp-installer.pkg" && echo "  Removed bin/dart-dev-mcp-installer.pkg"
  
  echo "Clean complete!"
}

do_release_macos() {
  # https://scriptingosx.com/2021/07/notarize-a-command-line-tool-with-notarytool/
  checkVar "$DEV_CERTIFICATE" DEV_CERTIFICATE 
  checkVar "$DEV_APP_CERTIFICATE" DEV_APP_CERTIFICATE
  checkVar "$DEV_IDENTIFIER" DEV_IDENTIFIER
  checkVar "$DEV_CREDENTIAL_PROFILE" DEV_CREDENTIAL_PROFILE

  # Check if xcode-select is pointing to Nix
  XCODE_PATH=$(which xcode-select)
  if [ $? -eq 0 ] && echo "$XCODE_PATH" | grep -q '/nix/store'; then
    echo "ERROR: xcode-select is pointing to a Nix path: $XCODE_PATH" >&2
    echo "" >&2
    echo "The notarytool requires native macOS SDKs, not Nix versions." >&2
    echo "Please exit your nix-shell and run this script in a normal terminal." >&2
    echo "" >&2
    echo "If you're not in a nix-shell, reset xcode-select with:" >&2
    echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
    echo "  # or" >&2
    echo "  sudo xcode-select --switch /Library/Developer/CommandLineTools" >&2
    exit 1
  fi

  # Build list of binary names (with hyphens)
  local binary_names=""
  for binary in $BINARIES; do
    binary_names="$binary_names ${binary//_/-}"
  done
  
  echo "******************************************************"
  echo "Releasing:$binary_names"
  echo "******************************************************"
  echo

  # Check that binaries exist
  for binary in $BINARIES; do
    local output_name="${binary//_/-}"
    if [ ! -f "bin/$output_name" ]; then
      echo "You have not yet built $output_name, please run '$0 build-macos' and retry the release." >&2
      exit 1
    fi
  done

  PKG="bin/dart-dev-mcp-installer"
  VERSION=$(grep -E '^version: ' pubspec.yaml | awk '{print $2}')

  # Clean up previous build artifacts
  [ -d "$PKG" ] && rm -rf "$PKG"
  [ -f "$PKG.pkg" ] && rm -f "$PKG.pkg"

  mkdir "$PKG"

  # Sign and stage all binaries
  for binary in $BINARIES; do
    local output_name="${binary//_/-}"
    cp "bin/$output_name" "$PKG/"

    # Sign the application with hardened runtime
    # https://lessons.livecode.com/m/4071/l/1122100-codesigning-and-notarizing-your-lc-standalone-for-distribution-outside-the-mac-appstore
    codesign --deep --force --verify --verbose --timestamp --options runtime \
      --sign "$DEV_APP_CERTIFICATE" \
      --entitlements "bin/entitlements.plist" \
      "$PKG/$output_name"
  done

  # Create single package containing all binaries
  pkgbuild --root "$PKG" \
        --identifier "$DEV_IDENTIFIER" \
        --version "$VERSION" \
        --install-location "/usr/local/bin" \
        --sign "$DEV_CERTIFICATE" \
        "$PKG.pkg"

  # Notarize
  xcrun notarytool submit "$PKG.pkg" \
    --keychain-profile "$DEV_CREDENTIAL_PROFILE" \
    --wait

  # Staple the notarization ticket
  xcrun stapler staple "$PKG.pkg"
  
  echo ""
  echo "Release complete! Installer package: $PKG.pkg"
}

do_list_identities() {
  security find-identity -p basic -v
}

do_create_keychain_profile() {
  echo "Creating keychain profile for notarytool..."
  echo ""
  echo "You will be prompted for:"
  echo "  - Profile name (e.g., dart-dev-mcp)"
  echo "  - Developer Apple ID (your email)"
  echo "  - Developer Team ID (from list-identities)"
  echo "  - App-specific password (from appleid.apple.com)"
  echo ""
  xcrun notarytool store-credentials
}

do_notarytool_log() {
  if [ -z "$LOG_ID" ]; then
    echo "Error: --log-id is required for notarytool-log" >&2
    exit 1
  fi
  checkVar "$DEV_CREDENTIAL_PROFILE" DEV_CREDENTIAL_PROFILE
  xcrun notarytool log "$LOG_ID" --keychain-profile "$DEV_CREDENTIAL_PROFILE"
}

# Parse options first
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      show_help
      exit 0
      ;;
    --env=*)
      ENV="${arg#*=}"
      source "$ENV"
      ;;
    --log-id=*)
      LOG_ID="${arg#*=}"
      ;;
  esac
done

# Get command (first non-option argument)
CMD=""
for arg in "$@"; do
  case "$arg" in
    --*) ;;
    *)
      CMD="$arg"
      break
      ;;
  esac
done

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
  release-macos)
    do_release_macos
    ;;
  list-identities)
    do_list_identities
    ;;
  create-keychain-profile)
    do_create_keychain_profile
    ;;
  notarytool-log)
    do_notarytool_log
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    echo ""
    show_help
    exit 1
    ;;
esac
