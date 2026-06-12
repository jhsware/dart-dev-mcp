# planner_remote_mcp

A drop-in replacement for the local `planner` MCP (`packages/planner`) that
proxies every operation to a **planner_server** over HTTPS instead of opening
`planner.db` directly.

The tool surface is **identical** — one `planner` tool with the same `operation`
enum (28 operations), the same parameters, and the same JSON result shapes — so
agent prompts and skills need no changes. Only the storage backend moves from a
local SQLite file to the server's HTTP API.

The existing `packages/planner` MCP is left untouched so both can run
side-by-side during the migration; deprecate the local one only after cutover.

## Usage

```bash
dart run packages/planner_remote/bin/planner_remote_mcp.dart \
  --project-dir=/path/to/project \
  --server-url=https://localhost:9444 \
  --token=$PLANNER_TOKEN \
  --ca-cert=/path/to/ca.crt          # pin the server CA (recommended)
# mTLS instead of / in addition to a token:
#   --client-cert=/path/client.crt --client-key=/path/client.key
# dev only:
#   --insecure
```

Every flag has an env-var fallback: `PLANNER_SERVER_URL`,
`PLANNER_SERVER_TOKEN`, `PLANNER_SERVER_CA_CERT`, `PLANNER_SERVER_CLIENT_CERT`,
`PLANNER_SERVER_CLIENT_KEY`, `PLANNER_SERVER_INSECURE`.

`--project-dir` is repeatable; the basename of each path is used as the
`{project}` segment in server URLs (e.g. `/projects/<basename>/tasks`). The
server resolves it by project id, then name, then `basename(local_path)`.

## Registering with the jhsware-code plugin

Add a second MCP entry alongside the existing `planner` one so both are
available during migration. In the plugin's MCP manifest (`.mcp.json` /
`.claude-plugin/plugin.json`):

```jsonc
{
  "mcpServers": {
    "planner": { /* existing local MCP — unchanged */ },
    "planner-remote": {
      "command": "dart",
      "args": [
        "run", "packages/planner_remote/bin/planner_remote_mcp.dart",
        "--project-dir=/abs/path/to/project",
        "--server-url=https://localhost:9444"
      ],
      "env": { "PLANNER_SERVER_TOKEN": "…", "PLANNER_SERVER_CA_CERT": "…" }
    }
  }
}
```

At cutover, point the `planner` registration at this binary and retire the
local one.

## Tests

```bash
dart test packages/planner_remote
```

Covers config parsing and the operation→HTTP method/path mapping against an
in-process mock server.
