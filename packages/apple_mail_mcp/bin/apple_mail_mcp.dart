import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'package:apple_mail_mcp/apple_mail_mcp.dart';

void main() async {
  final server = createAppleMailServer();
  final transport = StdioServerTransport();
  await server.connect(transport);
  stderr.writeln('Apple Mail MCP Server running on stdio');
}
