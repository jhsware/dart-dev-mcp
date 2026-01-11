import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

/// Creates a CallToolResult with text content.
///
/// This is a common helper used across all MCP servers to wrap
/// plain text responses in the proper MCP result format.
CallToolResult textResult(String text) {
  return CallToolResult.fromContent(
    content: [TextContent(text: text)],
  );
}

/// Creates a CallToolResult with JSON content.
///
/// This is a common helper for returning structured data responses,
/// automatically formatting the JSON with indentation.
CallToolResult jsonResult(Map<String, dynamic> data) {
  return CallToolResult.fromContent(
    content: [TextContent(text: JsonEncoder.withIndent('  ').convert(data))],
  );
}
