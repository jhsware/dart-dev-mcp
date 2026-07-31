# Rename packages and tools to the jhsware_code naming convention

Date: 2026-07-31
Branch: `task/rename-jhsware-code-packages`
Planner task: `94d16c46-7cb4-4bad-b9f7-bc79fce46aa9`

## Goal

The project packages started with generic names. This change renames packages
so the `jhsware_code` prefix shows that they are part of the jhsware_code
project, while tools keep simple names.

## The convention

| Kind | Pattern | Example |
|------|---------|---------|
| Dart package (pubspec `name:`) | `jhsware_code_<tool>` (snake_case) | `jhsware_code_filesystem` |
| MCP tool name | `<tool>` with dashes (easy to type) | `filesystem`, `dart-runner`, `git` |
| Bin entrypoint | `bin/<tool>_mcp.dart` | `bin/filesystem_mcp.dart` |
| Compiled binary | `jhsware-code-<tool>` | `jhsware-code-filesystem` |
| MCP server key (claude.sh, persona, mcp config) | `jhsware_code_<tool>` | `jhsware_code_git` |
| MCP server Implementation name | `jhsware_code_<tool>` | `jhsware_code_planner` |

Decision note: a first iteration renamed the tools to snake_case
(`dart_runner`). This was reverted the same day — dashes are more natural to
type for tool names. Final rule: code identifiers (packages, server keys) use
snake_case, tool names use dashes.

## Package renames (pubspec `name:` + all `package:` imports)

| Old | New |
|-----|-----|
| `dart_dev_mcp` (root) | `jhsware_code` |
| `filesystem_mcp` | `jhsware_code_filesystem` |
| `git_mcp` | `jhsware_code_git` |
| `dart_runner_mcp` | `jhsware_code_dart_runner` |
| `flutter_runner_mcp` | `jhsware_code_flutter_runner` |
| `fetch_mcp` | `jhsware_code_fetch` |
| `planner_mcp` | `jhsware_code_planner` |
| `code_index_mcp` | `jhsware_code_code_index` |
| `apple_mail_mcp` | `jhsware_code_apple_mail` |
| `jhsware_code_shared_libs` | unchanged (already followed the convention) |

## Tool names

Tool names keep their simple dashed form: `filesystem`, `git`, `planner`,
`fetch`, `dart-runner`, `flutter-runner`, `code-index`, `apple-mail`,
`fetch-and-transform`. One rename for consistency: `fetch_links` →
`fetch-links`. Log and error tags inside the servers use the same dashed
names.

## Binary renames (build.sh, claude.sh)

| Old | New |
|-----|-----|
| `file-edit-mcp` | `jhsware-code-filesystem` |
| `git-mcp` | `jhsware-code-git` |
| `dart-runner-mcp` | `jhsware-code-dart-runner` |
| `flutter-runner-mcp` | `jhsware-code-flutter-runner` |
| `fetch-mcp` | `jhsware-code-fetch` |
| `planner-mcp` | `jhsware-code-planner` |
| `code-index-mcp` | `jhsware-code-code-index` |
| `apple-mail-mcp` | `jhsware-code-apple-mail` |

Also: `apple_mail_mcp` is now part of the standard `build.sh` build list (it
was missing before although claude.sh referenced its binary). The macOS
installer is now `bin/jhsware-code-installer.pkg`.

## Entrypoint rename

`packages/filesystem/bin/file_edit_mcp.dart` → `packages/filesystem/bin/filesystem_mcp.dart`.
The old file remains as a small deprecated forwarder so existing scripts keep
working. Delete `file_edit_mcp.dart` when nothing references it (I cannot
delete files; please remove it when you are ready).

## Backwards compatibility (project permission files)

`ProjectConfigService` (packages/shared_libs/lib/src/project_config.dart) was
extended so existing permission files keep working without edits:

1. **File names.** The preferred config file name is now `jhsware_code.yaml`.
   The legacy `jhsware-code.yaml` is still accepted. If both exist, the
   preferred name wins. The cache tracks the config file path plus its
   modification time, so switching files invalidates correctly.
2. **Tool keys.** Config keys and tool-name lookups are matched in canonical
   form: hyphens and underscores are interchangeable (`canonicalToolName`
   maps both to underscores internally). `code-index:` and `code_index:`
   both address the `code-index` tool.

Tests in `packages/shared_libs/test/project_config_test.dart` cover the
legacy file name, precedence, hyphen/underscore key matching in both
directions, and cache invalidation when the preferred file appears.

## Other updated surfaces

- `claude.sh`: server keys are now `jhsware_code_<tool>`, production commands
  use the new binary names, dev mode maps `filesystem_mcp.dart`, and the
  backup file suffix is `.jhsware_code.bak`. CLI server selectors (`fs`,
  `dart`, `code-index`, ...) are unchanged on purpose (user-facing shorthand).
- `agentic-plugins/jhsware-code`: skills/agents keep the dashed tool names in
  `tools:` / `allowed-tools:`; server-name parentheticals in the text now say
  `jhsware_code_<tool>`. The stale `convert` tool (merged into fetch long
  ago) was removed from allowed-tools lists.
- `agentic-personas/flutter-developer-persona/persona.yaml`: mcpServers keys
  are `jhsware_code_<tool>`; the filesystem entry points at
  `filesystem_mcp.dart`; allowedTools keep the dashed tool names.
- `shared_libs/prompt_pack.dart`: task prompts now say
  "planner (jhsware_code_planner)".
- `README.md` (root): rewritten for the convention, with a naming table. The
  config example was also corrected — the parser expects a flat path list per
  tool key, not an `allowed_paths:` sub-key as the old README showed.
- `packages/code_index/README.md`, `packages/planner/README.md`: updated.
- `CHANGELOG.md`: new BREAKING entry with the full rename map.
- Root `test/servers/*`: updated to the new entrypoint and log strings. Two
  stale code_index tests still expected the removed `--planner-data-root`
  requirement (one timed out, one failed on help text); they were updated to
  the v2 `--data-root` behaviour.

## Deliberately not renamed

- **Tool names**: keep dashes (see decision note above).
- **Package directories** (`packages/filesystem`, ...): the MCP toolset has no
  move operation, so directories keep their simple names. This also reads
  well: `packages/<tool>/`. `packages/apple_mail_mcp/` is the one directory
  with an `_mcp` suffix; a later `git mv apple_mail_mcp apple_mail` would
  harmonise it if wanted.
- **Operation names** (`read-file`, `branch-create`, ...): part of the tool
  API used by skills and agents in many projects. Note: a few operations use
  underscores (`get_output`, `list_sessions`); harmonising them to dashes
  would be a separate breaking change.
- **Code-index data root** `~/.code-index`: renaming would orphan existing
  index stores.
- **GitHub repository URL** (`github.com/jhsware/dart_dev_mcp`): renaming the
  remote repository is your call; pubspec `repository:` fields keep the
  current URL so links stay valid.
- **Skill/agent names** in the plugin (`jhsware-code:code-index`, ...).

## Not reachable from this session

- `agentic-plugins/jhsware-code/.claude-plugin/plugin.json` and other hidden
  files (`.github`, `.gitignore`, the repo's own `jhsware-code.yaml`) are
  outside the filesystem tool's allowed paths. Check plugin.json manually if
  it references tool or server names. You may also want to rename the repo's
  own `jhsware-code.yaml` to `jhsware_code.yaml` (both now work).

## Migration notes

1. Rebuild and reinstall binaries: `./build.sh build-macos` then
   `./build.sh release-macos --env=.env` (or copy from `bin/`). Old
   `*-mcp` binaries in `/usr/local/bin` can be removed manually.
2. Claude sessions started via `claude.sh` will register servers under the
   new keys, so fully qualified tool ids change (e.g.
   `mcp__jhsware_code_git__git`, `mcp__jhsware_code_dart_runner__dart-runner`).
   Any allow-lists that pin the old `mcp__dart-dev-mcp-*` ids need updating —
   project `jhsware-code.yaml` permission files do NOT need changes.
3. Rebuild the plugin zip with `./build-plugins.sh` to publish the updated
   skills/agents.
4. Delete `packages/filesystem/bin/file_edit_mcp.dart` (forwarder) when
   nothing references it any more.
5. Anything that called the fetch server's `fetch_links` tool must call
   `fetch-links` now.

## Verification

- `dart pub get`: workspace resolves with the new package names.
- `dart analyze`: no issues (run again after the dash revert).
- Tests: shared_libs 250 passed; filesystem 45 passed; planner 14 passed;
  code_index 101 passed; git 71 passed; apple_mail 110 passed (9 integration
  suites skipped — require Apple Mail); root server tests all passed after the
  two stale code_index argument tests were fixed. Re-run after the dash
  revert: analyze plus shared_libs and root server suites green.
- `dart format`: repo formatted with the pinned SDK. The formatter in the
  current pinned SDK is newer than the one used for the last format commit,
  so it reformatted ~100 files repo-wide. This churn is committed separately
  (`style:` commit) to keep the rename diff reviewable.
