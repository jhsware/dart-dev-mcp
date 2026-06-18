import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:planner_mcp/planner_mcp.dart';

/// Planner MCP Server.
///
/// Same tool surface as the local `planner` MCP, but proxies every operation to
/// a planner_server over HTTPS instead of opening planner.db directly.
///
/// Usage:
///   planner_mcp --project-dir=PATH [--project-dir=PATH2 ...] \
///     --server-url=https://host:9444 --token=BEARER \
///     [--ca-cert=PATH] [--client-cert=PATH --client-key=PATH] [--insecure]
void main(List<String> arguments) async {
  final config = PlannerConfig.parse(arguments);

  if (config.helpRequested) {
    _printUsage();
    exit(0);
  }
  if (config.projectDirs.isEmpty) {
    stderr.writeln('Error: at least one --project-dir is required\n');
    _printUsage();
    exit(1);
  }
  for (final dir in config.projectDirs) {
    if (!Directory(dir).existsSync()) {
      stderr.writeln('Error: Project path does not exist: $dir');
      exit(1);
    }
  }

  final client = PlannerApiClient.fromConfig(config);

  final server = McpServer(
    Implementation(name: 'planner-mcp', version: '1.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
    ),
  );

  registerPlannerTool(server, client, config);

  final transport = StdioServerTransport();
  await server.connect(transport);
  stderr.writeln('Planner MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln(
      'Usage: planner_mcp --project-dir=PATH [--project-dir=PATH2 ...] '
      '--server-url=URL [--token=TOKEN] [--ca-cert=PATH] '
      '[--client-cert=PATH --client-key=PATH] [--insecure]');
  stderr.writeln('');
  stderr.writeln('Options (env-var fallback in parentheses):');
  stderr.writeln('  --project-dir=PATH   Project directory (repeatable, required)');
  stderr.writeln('  --server-url=URL     planner_server base URL (PLANNER_SERVER_URL)');
  stderr.writeln('  --token=TOKEN        Bearer token (PLANNER_SERVER_TOKEN)');
  stderr.writeln('  --ca-cert=PATH       Pin server CA (PLANNER_SERVER_CA_CERT)');
  stderr.writeln('  --client-cert=PATH   mTLS client cert (PLANNER_SERVER_CLIENT_CERT)');
  stderr.writeln('  --client-key=PATH    mTLS client key (PLANNER_SERVER_CLIENT_KEY)');
  stderr.writeln('  --insecure           Skip TLS verification (PLANNER_SERVER_INSECURE)');
  stderr.writeln('  --help, -h           Show this help');
}
