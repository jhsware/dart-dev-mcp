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

## Inventory: references to the old mcp__dart-dev-mcp-* ids (2026-07-31)

Search across all project directories registered with this session's
filesystem server (pattern `dart-dev-mcp` / `mcp__dart`, case-insensitive).
These references break when the new `jhsware_code_<tool>` server keys are in
use, so they must be updated in sync with the switch.

### jhsware_code (this repo)

Clean. No `dart-dev-mcp` references remain in packages, plugins, personas,
scripts or docs (historical design docs in `packages/code_index/docs` were
left as records and contain none either).

### builder_server (~/DEV/agentic-coding/builder/builder_server)

Functional code:
- `lib/src/agent/mcp_config_builder.dart` L118-119 — writes the
  `dart-dev-mcp-planner` server key into generated mcp configs.
- `lib/src/persona/mcp_inventory_service.dart` L101 —
  `_plannerServerName = 'dart-dev-mcp-planner'`.

Prompts:
- `lib/src/prompts/templates/app_prompt_shared.md` L24-31 and the generated
  `lib/src/prompts/prompt_pack_defaults.g.dart` L128-135 — text references
  `dart-dev-mcp-planner/fs/git/flutter-runner/dart-runner`.

Docs: `docs/design/persona-mcp-env-vars.md` L94.

Tests (assert the old names): `test/mcp_handlers_test.dart`,
`test/config/server_config_planner_mcp_test.dart`,
`test/mcp_config_env_injection_test.dart`, `test/agent/mcp_readiness_test.dart`
(also full ids `mcp__dart-dev-mcp-planner__planner`,
`mcp__dart-dev-mcp-fs__filesystem`), `test/agent/mcp_config_server_names_test.dart`,
`test/agent/mcp_config_builder_test.dart`, `test/mcp_inventory_test.dart`.

### builder_app (~/DEV/agentic-coding/builder/builder_app)

- `lib/ui/widgets/chat/tool_bubble/renderers/tool_renderer_registry.dart` L39 —
  functional renderer key `'mcp__dart-dev-mcp-planner__planner'`.
- `lib/ui/widgets/chat/tool_bubble/renderers/planner_tool_renderer.dart` L16
  and `lib/utils/tool_name_formatter.dart` L4-8 — comments/examples.

### planner_app (~/DEV/agentic-coding/planner/planner_app)

- `packages/planner_models/lib/src/mcp_server_config.dart` L585-678 —
  functional default server definitions: `dart-dev-mcp-planner`, `-fs`,
  `-git`, `-flutter`, `-convert`, `-fetch`. Note: `-flutter` and `-convert`
  were already stale before this rename (claude.sh used `-flutter-runner`;
  convert was merged into fetch).
- `packages/task_views/lib/src/prompt_resolver.dart` L73 — prompt text
  `planner (dart-dev-mcp-planner)`.
- `docs/schema_docs.md` — schema examples with the old server names.

### sysops_server (~/DEV/agentic-coding/sysops/sysops_server)

- `lib/src/agent/agent_runner.dart` L1443 — functional allow-list entry
  `'mcp__dart-dev-mcp-git__git'`.
- `packages/planner_mcp/skills/planner-plan/SKILL.md` L283-285 — vendored
  skill copy referencing `dart-dev-mcp-fs/git/fetch`.

### sysops_app (~/DEV/agentic-coding/sysops/sysops_app)

- `packages/chat_ui_component/lib/src/widgets/tool_bubble/renderers/tool_renderer_registry.dart`
  L18 — functional renderer key `'mcp__dart-dev-mcp-planner__planner'`.
- `packages/agent_chat_ui/test/tool_content_parser_test.dart` L7 — test
  expects `mcp__dart-dev-mcp-fs__filesystem` → `Filesystem`.
- `tool_name_formatter.dart` doc comments in both packages.

### Clean (searched, no hits)

builder_server/bin, planner_server, sysops_app/lib+docs, sysops_server/lib
(other than above), nix-infra, mcp-collection, jhsware_business (+ AGENTS.md,
docs, packages), jhsware_business_desktop_app, veckoappen backend projects,
veckoappen app docs, gardsman server/app docs, nasp-waves projects,
whisper_ggml_plus, bmd_switcher_sdk docs, nix-pretty src, agriculture.

### Additional findings from manual grep (2026-08-01)

The user ran `grep -rn "dart-dev-mcp" ~/DEV ~/RESEARCH` (the filesystem tool
could not reach these locations). Confirmed additional references:

Personas repo (`~/DEV/agentic-coding/personas`) — allowedTools lists,
mcpServers keys and system_prompt.md tool references in six personas:
- `dart-developer` (persona.yaml L142-146, L186-203)
- `nix-infra-secops-researcher` (persona.yaml + system_prompt.md L45-46)
- `nix-infra-devops` (persona.yaml + system_prompt.md L49-50)
- `nix-infra-sysops-server-probe` (persona.yaml + system_prompt.md L32)
- `nix-infra-sysops` (persona.yaml + system_prompt.md L46-47)
- `flutter-developer` (persona.yaml, incl. `dart-dev-mcp-flutter-runner`)

Test directories that my per-directory search missed:
- sysops_app: `test/features/chat/widgets/tool_bubble/renderers/tool_renderer_registry_test.dart`,
  `test/features/chat/widgets/tool_bubble_test.dart`
- sysops_server: `test/agent/process_manager_test.dart` L196,
  `test/agent/agent_runner_appendix_test.dart` L152
- builder_app: `test/tool_name_formatter_test.dart`,
  `test/ui/widgets/mcp_env_vars_dialog_planner_cert_test.dart` L24,
  `test/server_connection_cubit_planner_token_test.dart` L98
- planner_app: `test/models/project_config_test.dart` (many), plus
  `README.md` L103/L232 (`~/dev/dart-dev-mcp` source dir, toolset mention)

Standalone scripts and configs outside registered projects:
- `~/DEV/urbantalk-server-fleet/cli` L833-930 — embedded mcp config JSON with
  `dart-dev-mcp-fs/git/planner` keys
- `~/DEV/nixos-infect/claude.sh` — old launcher copy with `dart-dev-mcp-*`
  keys and `.dart-dev-mcp.bak` suffix
- `~/DEV/veckoappen-dart-backend/claude.sh` — old launcher copy
  (`.dart-dev-mcp.bak` suffix)
- `~/DEV/planner_viewer_migration.sh` L29 (`server: dart-dev-mcp`)

Vendored `agent_chat_ui` copies (same formatter doc + test in each host app):
- `~/DEV/nasp-waves/nasp_waves_backend_app/packages/agent_chat_ui` (plus a
  `.worktrees` copy)
- already listed: sysops_app `packages/agent_chat_ui`

Binary matches (build/, .dart_tool/, kernel blobs, .dill) are build artifacts;
they disappear on the next build. `~/.claude` and per-project `.claude/`
settings were not part of this grep and remain unchecked.

### Suggested update order

1. Switch jhsware_code (this branch) and rebuild binaries.
2. Update the functional integration points that generate or match server
   keys: builder_server `mcp_config_builder.dart` + `mcp_inventory_service.dart`,
   planner_app `mcp_server_config.dart` defaults, sysops_server
   `agent_runner.dart` allow-list, the chat renderer registries (builder_app,
   sysops_app chat_ui_component), and every vendored `agent_chat_ui` copy.
3. Update the six personas in `~/DEV/agentic-coding/personas` (allowedTools,
   mcpServers keys, system prompts) and re-zip/re-upload them.
4. Replace or delete the old launcher copies (`nixos-infect/claude.sh`,
   `veckoappen-dart-backend/claude.sh`) and update
   `urbantalk-server-fleet/cli` mcp config blocks.
5. Update prompts, skills, docs and tests in the listed projects.
6. Check `~/.claude` and per-project `.claude/` settings for pinned
   `mcp__dart-dev-mcp-*` ids.
