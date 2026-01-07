/// Dart Dev MCP - Main entry point
///
/// This package provides multiple MCP server binaries:
/// - file_edit_mcp.dart - File system operations
/// - convert_to_md_mcp.dart - HTML to Markdown conversion
/// - fetch_mcp.dart - URL fetching
/// - dart_runner_mcp.dart - Dart program runner
/// - flutter_runner_mcp.dart - Flutter program runner
///
/// Run the specific binary you need, not this file.
void main(List<String> arguments) {
  print('Dart Dev MCP');
  print('============');
  print('');
  print('This package provides multiple MCP servers.');
  print('Please run one of the specific binaries:');
  print('');
  print('  dart run bin/file_edit_mcp.dart [allowed_paths...]');
  print('  dart run bin/convert_to_md_mcp.dart');
  print('  dart run bin/fetch_mcp.dart');
  print('  dart run bin/dart_runner_mcp.dart [project_path]');
  print('  dart run bin/flutter_runner_mcp.dart [project_path]');
}
