# planner_mcp

The Planner MCP server: task and step management for AI-assisted development.
It proxies every operation to a **planner_server** over HTTPS rather than
opening a local `planner.db`.

One `planner` tool exposes the full `operation` enum (29 operations) with the
same parameters and JSON result shapes, so agent prompts and skills target it
unchanged.

## Usage

```bash
dart run packages/planner/bin/planner_mcp.dart \
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

`create-project` and `list-projects` are the two operations that do **not**
require `project_dir`. `create-project` provisions a project on the server from
a `local_path` (optional `name`) via `POST /projects`, returning the project
record (`id`, `name`, `local_path`, `has_instructions`).

## Tests

```bash
dart test packages/planner
```

Covers config parsing and the operation→HTTP method/path mapping against an
in-process mock server.
