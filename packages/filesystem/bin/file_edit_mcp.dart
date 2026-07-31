/// Deprecated entrypoint kept for backwards compatibility.
///
/// The filesystem MCP server entrypoint moved to `bin/filesystem_mcp.dart`
/// (package `jhsware_code_filesystem`, binary `jhsware-code-filesystem`).
/// This forwarder only delegates to the new entrypoint. Delete this file
/// when nothing references `file_edit_mcp.dart` any more.
library;

import 'filesystem_mcp.dart' as filesystem_mcp;

void main(List<String> arguments) => filesystem_mcp.main(arguments);
