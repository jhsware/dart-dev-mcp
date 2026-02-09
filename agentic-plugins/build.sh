#!/usr/bin/env bash
set -euo pipefail

# --- 1. Check for uncommitted changes ---
if [ -n "$(git status --porcelain)" ]; then
  echo "⚠️  There are uncommitted changes in the workspace:"
  echo ""
  git status --short
  echo ""
  read -rp "Please commit or stash them before continuing. Press Enter when ready..."

  # Re-check after user confirms
  if [ -n "$(git status --porcelain)" ]; then
    echo "❌ There are still uncommitted changes. Aborting."
    exit 1
  fi
fi

echo "✅ Working directory is clean."
echo ""

# --- 2 & 3. Bump minor version, commit and tag each plugin ---
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

  # Parse semver components (supports X.Y and X.Y.Z)
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

  # Update version in plugin.json
  sed -i '' "s/\"version\"\([[:space:]]*\):\([[:space:]]*\)\"${current_version}\"/\"version\"\1:\2\"${new_version}\"/" "$plugin_json"

  # Commit and tag
  tag="v${new_version}"
  git add "$plugin_json"
  git commit -m "${tag}" -- "$plugin_json"
  git tag "$tag"

  updated_plugins+=("${name}: ${current_version} -> ${new_version}")
done

# --- 4. List updated plugins ---
echo ""
if [ ${#updated_plugins[@]} -eq 0 ]; then
  echo "No plugins found to update."
  exit 0
fi

echo "📦 Updated plugins:"
for entry in "${updated_plugins[@]}"; do
  echo "  - $entry"
done
echo ""

# --- 5. Zip each subdirectory ---
for dir in */; do
  [ -d "$dir" ] || continue
  name="${dir%/}"
  echo "Zipping: $name -> ${name}.zip"
  rm -f "${name}.zip"
  zip -r "${name}.zip" "$name"
done

echo ""
echo "Done."
