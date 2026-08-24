import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'package:jhsware_code_apple_mail/apple_mail_mcp.dart';

void main() async {
  final server = createAppleMailServer();
  final transport = StdioServerTransport();
  await server.connect(transport);
  stderr.writeln('Apple Mail MCP Server running on stdio');
}
