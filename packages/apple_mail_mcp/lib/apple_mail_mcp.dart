/// Read-only Apple Mail MCP server for Dart.
///
/// Provides a single `apple-mail` tool with 18 read-only operations
/// for listing, searching, and exporting emails from Apple Mail.
library;

export 'src/server.dart' show createAppleMailServer, allOperations;
export 'src/operations/inbox.dart' show getInboxOperations;
export 'src/operations/search.dart' show getSearchOperations;
export 'src/operations/attachments.dart' show getAttachmentOperations;
export 'src/core.dart' show runAppleScript, escapeAppleScript, parseEmailList;
export 'src/constants.dart';
