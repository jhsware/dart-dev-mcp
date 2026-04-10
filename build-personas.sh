#!/usr/bin/env bash
set -euo pipefail

# --- 0. Setup Environment ---
# Automatically move to the git root to fix "failed to write commit object" errors
cd "$(git rev-parse --show-toplevel)"

# Define the target sub-folders
PERSONA_BASE_DIR="agentic-personas"
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

# --- 3. Validate directories exist ---
if [ ! -d "$PERSONA_BASE_DIR" ]; then
  echo "❌ Error: Directory '$PERSONA_BASE_DIR' not found."
  exit 1
fi

if [ ! -d "$PLUGIN_BASE_DIR" ]; then
  echo "❌ Error: Directory '$PLUGIN_BASE_DIR' not found."
  exit 1
fi

# --- 4. Collect plugin source directories ---
# These are subdirectories in agentic-plugins/ (not zip files)
declare -a plugin_dirs=()
for pdir in "$PLUGIN_BASE_DIR"/*/; do
  [ -d "$pdir" ] || continue
  plugin_dirs+=("$pdir")
done

if [ ${#plugin_dirs[@]} -eq 0 ]; then
  echo "⚠️  No plugin source directories found in '$PLUGIN_BASE_DIR'. Personas will be built without plugins."
fi

# --- 5. Bump minor version, commit, tag, and zip each persona ---
declare -a updated_personas=()

for dir in "$PERSONA_BASE_DIR"/*/; do
  [ -d "$dir" ] || continue
  persona_yaml="${dir}persona.yaml"
  [ -f "$persona_yaml" ] || continue

  # Extract folder name (e.g., "flutter-developer-persona")
  name=$(basename "$dir")

  # Read current version from persona.yaml
  current_version=$(sed -n 's/^version:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$persona_yaml")
  if [ -z "$current_version" ]; then
    echo "⚠️  Skipping $name: no version found in $persona_yaml"
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

  # Update version in persona.yaml
  escaped_current=$(printf '%s' "$current_version" | sed 's/\./\\./g')
  sed_cmd "s/^\(version:[[:space:]]*\"\{0,1\}\)${escaped_current}\(\"\{0,1\}[[:space:]]*\)$/\1${new_version}\2/" "$persona_yaml"

  # Only commit if the file actually changed
  if git diff --quiet "$persona_yaml"; then
    echo "⏩ No changes detected for $name. Skipping."
    continue
  fi

  # Commit and tag
  tag="${name}-v${new_version}"
  git add "$persona_yaml"

  if git commit -m "chore: bump persona $name to v${new_version}" -- "$persona_yaml"; then
    git tag -a "$tag" -m "Release $tag"
    updated_personas+=("${name}: ${current_version} -> ${new_version}")
  else
    echo "❌ Error: Failed to commit $name. Check permissions or disk space."
    exit 1
  fi
done

# --- 6. Summary ---
echo ""
if [ ${#updated_personas[@]} -eq 0 ]; then
  echo "No personas were updated."
else
  echo "📦 Updated personas:"
  for entry in "${updated_personas[@]}"; do
    echo "  - $entry"
  done
fi

# --- 7. Zip each persona (with plugins bundled) ---
echo ""
for dir in "$PERSONA_BASE_DIR"/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  [ -f "${dir}persona.yaml" ] || continue

  # Read the current version (after bump)
  version=$(sed -n 's/^version:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "${dir}persona.yaml")
  if [ -z "$version" ]; then
    echo "⚠️  Skipping zip for $name: no version found."
    continue
  fi

  zip_file="${PERSONA_BASE_DIR}/${name}_${version}.zip"

  if [ -f "$zip_file" ]; then
    echo "❌ Error: The file $zip_file already exists. Aborting!"
    exit 1
  fi

  # Copy plugin source directories into persona's plugins/ directory
  plugins_dir="${dir}plugins"
  mkdir -p "$plugins_dir"

  for pdir in "${plugin_dirs[@]}"; do
    plugin_name=$(basename "$pdir")
    target="${plugins_dir}/${plugin_name}"

    # Remove any previous copy to ensure clean state
    if [ -d "$target" ]; then
      rm -rf "$target"
    fi

    echo "  Bundling plugin: $plugin_name -> $name/plugins/$plugin_name"
    cp -R "$pdir" "$target"
  done

  echo "Zipping: $name -> $zip_file"
  # Run zip from the persona's parent directory to keep folder structure clean
  (cd "$PERSONA_BASE_DIR" && zip -r -q "./${name}_${version}.zip" "$name" -x "*.DS_Store*" "*.git*")

  # Clean up: remove copied plugin directories from persona source
  for pdir in "${plugin_dirs[@]}"; do
    plugin_name=$(basename "$pdir")
    target="${plugins_dir}/${plugin_name}"
    if [ -d "$target" ]; then
      rm -rf "$target"
    fi
  done
done

echo ""
echo "Done."
