#!/usr/bin/env bash
set -euo pipefail

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

# Clear any stale git locks that might cause "failed to write" errors
rm -f .git/index.lock

echo "✅ Working directory is clean."
echo ""

# --- 2. Define cross-platform sed ---
# macOS sed requires -i '', while GNU sed (Linux) just uses -i
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed_cmd=(sed -i '')
else
  sed_cmd=(sed -i)
fi

# --- 3. Bump minor version, commit and tag each plugin ---
declare -a updated_plugins=()

for dir in */; do
  [ -d "$dir" ] || continue
  plugin_json="${dir}.claude-plugin/plugin.json"
  [ -f "$plugin_json" ] || continue

  name="${dir%/}"

  # Read current version (macOS-compatible)
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

  # Bump minor, reset patch if present
  new_minor=$((minor + 1))
  if [ -n "$patch" ]; then
    new_version="${major}.${new_minor}.0"
  else
    new_version="${major}.${new_minor}"
  fi

  # Update version in plugin.json using the platform-specific sed command
  "${sed_cmd[@]}" "s/\"version\"\([[:space:]]*\):\([[:space:]]*\)\"${current_version}\"/\"version\"\1:\2\"${new_version}\"/" "$plugin_json"

  # SAFETY CHECK: Only commit if the file actually changed
  if git diff --quiet "$plugin_json"; then
    echo "⏩ No changes detected for $name (Version might already be updated). Skipping."
    continue
  fi

  # Commit and tag with error handling
  tag="v${new_version}"
  git add "$plugin_json"
  
  if git commit -m "chore: bump $name to $tag" -- "$plugin_json"; then
    # Only tag if the commit succeeded
    git tag -a "$tag" -m "Release $tag for $name"
    updated_plugins+=("${name}: ${current_version} -> ${new_version}")
  else
    echo "❌ Error: Failed to commit changes for $name. Check disk space/permissions."
    exit 1
  fi
done

# --- 4. List updated plugins ---
echo ""
if [ ${#updated_plugins[@]} -eq 0 ]; then
  echo "No plugins were updated."
else
  echo "📦 Updated plugins:"
  for entry in "${updated_plugins[@]}"; do
    echo "  - $entry"
  done
fi
echo ""

# --- 5. Zip each subdirectory ---
for dir in */; do
  [ -d "$dir" ] || continue
  name="${dir%/}"
  # Avoid zipping the .git folder or hidden files if necessary
  echo "Zipping: $name -> ${name}.zip"
  rm -f "${name}.zip"
  zip -r -q "${name}.zip" "$name" -x "*.DS_Store*" "*.git*"
done

echo ""
echo "Done. All commits and tags created successfully."
