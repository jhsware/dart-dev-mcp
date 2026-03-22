/// Shared libraries for MCP servers.
///
/// This package provides common utilities used across all MCP server
/// implementations including error handling, HTTP client, logging,
/// path helpers, result formatting, session management, validation,
/// and SQLite helpers.
library;

export 'src/exceptions.dart';
export 'src/http_client.dart';
export 'src/line_endings.dart';
export 'src/logging.dart';
export 'src/path_helpers.dart';
export 'src/project_config.dart';

export 'src/prompt_pack_service.dart';
export 'src/result_helpers.dart';
export 'src/session_manager.dart';
export 'src/sqlite_helpers.dart';
export 'src/validation.dart';