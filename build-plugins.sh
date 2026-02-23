#!/usr/bin/env bash
set -euo pipefail

# --- 0. Setup Environment ---
# Automatically move to the git root to fix "failed to write commit object" errors
cd "$(git rev-parse --show-toplevel)"

# Define the target sub-folder for plugins
PLUGIN_BASE_DIR="agentic-plugins"

# Clear any stale git locks
rm -f .git/index.lock

# --- 1. Check for uncommitted changes ---
if [ -n "$(git status --porcelain)" ]; then
  echo "⚠️  There are uncommitted changes in the workspace:"
  echo ""
  git status --short
  echo ""
  read -rp "Please commit or stash them before continuing. Press Enter when ready..."

  if [ -n "$(git status --porcelain)" ]; then
    echo "❌ There are still uncommitted changes. Aborting."
    exit 1
  fi
fi

echo "✅ Working directory is clean."
echo ""

# --- 2. Define cross-platform sed ---
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed_cmd() {
    local file="${!#}"
    sed -i.bak "$@" && rm -f "${file}.bak"
  }
else
  sed_cmd() { sed -i "$@"; }
fi

# --- 3. Bump minor version, commit and tag each plugin ---
declare -a updated_plugins=()

# Search only inside the agentic-plugins directory
if [ ! -d "$PLUGIN_BASE_DIR" ]; then
    echo "❌ Error: Directory '$PLUGIN_BASE_DIR' not found."
    exit 1
fi

for dir in "$PLUGIN_BASE_DIR"/*/; do
  [ -d "$dir" ] || continue
  plugin_json="${dir}.claude-plugin/plugin.json"
  [ -f "$plugin_json" ] || continue

  # Extract folder name for messaging (e.g., "my-plugin" from "agentic-plugins/my-plugin/")
  name=$(basename "$dir")

  # Read current version
  current_version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$plugin_json")
  if [ -z "$current_version" ]; then
    echo "⚠️  Skipping $name: no version found in $plugin_json"
    continue
  fi

  # Parse semver components
  IFS='.' read -ra parts <<< "$current_version"
  major="${parts[0]}"
  minor="${parts[1]:-0}"
  patch="${parts[2]:-}"

  # Bump minor
  new_minor=$((minor + 1))
  new_version="${major}.${new_minor}${patch:+.0}"

  # Update version in plugin.json
  escaped_current=$(printf '%s' "$current_version" | sed 's/\./\\./g')
  sed_cmd "s/\"version\"\([[:space:]]*\):\([[:space:]]*\)\"${escaped_current}\"/\"version\"\1:\2\"${new_version}\"/" "$plugin_json"

  # Only commit if the file actually changed
  if git diff --quiet "$plugin_json"; then
    echo "⏩ No changes detected for $name. Skipping."
    continue
  fi

  # Commit and tag
  tag="v${new_version}"
  git add "$plugin_json"
  
  if git commit -m "chore: bump $name to $tag" -- "$plugin_json"; then
    git tag -a "$tag" -m "Release $tag for $name"
    updated_plugins+=("${name}: ${current_version} -> ${new_version}")
  else
    echo "❌ Error: Failed to commit $name. Check permissions or disk space."
    exit 1
  fi
done

# --- 4. Summary ---
echo ""
if [ ${#updated_plugins[@]} -eq 0 ]; then
  echo "No plugins were updated."
else
  echo "📦 Updated plugins:"
  for entry in "${updated_plugins[@]}"; do
    echo "  - $entry"
  done
fi

# --- 5. Zip each plugin ---
echo ""
for dir in "$PLUGIN_BASE_DIR"/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")

  if [ -f "./${name}_${new_version}.zip" ]; then
    echo "❌ Error: The file ${name}_${new_version}.zip already exists. Aborting!"
    exit 1
  fi

  echo "Zipping: $name -> ${name}_${new_version}.zip"
  # Run zip from the plugin's parent directory to keep folder structure clean
  (cd "$PLUGIN_BASE_DIR" && zip -r -q "./${name}_${new_version}.zip" "$name" -x "*.DS_Store*" "*.git*")
done

echo ""
echo "Done."
