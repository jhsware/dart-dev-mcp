import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'exceptions.dart';
import 'logging.dart';

/// Creates a CallToolResult with text content.
///
/// This is a common helper used across all MCP servers to wrap
/// plain text responses in the proper MCP result format.
CallToolResult textResult(String text) {
  return CallToolResult.fromContent(
    [TextContent(text: text)],
  );
}

/// Creates a CallToolResult with JSON content.
///
/// This is a common helper for returning structured data responses,
/// automatically formatting the JSON with indentation.
CallToolResult jsonResult(Map<String, dynamic> data) {
  return CallToolResult.fromContent(
    [TextContent(text: JsonEncoder.withIndent('  ').convert(data))],
  );
}

/// Creates an error CallToolResult with consistent formatting and logging.
///
/// This helper:
/// - Logs the error with context to stderr for debugging
/// - Returns a user-friendly error message
/// - Handles McpException types specially for better messages
///
/// The [operation] parameter identifies the operation for logging context.
/// The [context] parameter can include additional debugging information.
///
/// Example:
/// ```dart
/// try {
///   await performOperation();
/// } catch (e, stackTrace) {
///   return errorResult(
///     'planner:add-task',
///     e,
///     stackTrace,
///     context: {'project_id': projectId},
///   );
/// }
/// ```
CallToolResult errorResult(
  String operation,
  Object error, [
  StackTrace? stackTrace,
  Map<String, dynamic>? context,
]) {
  // Log the error with full context
  logError(operation, error, stackTrace, context);
  
  // Return a user-friendly error message
  final message = _formatErrorMessage(error);
  return textResult(message);
}

/// Formats an error into a user-friendly message.
///
/// For McpException types, uses the userMessage getter.
/// For other exceptions, prefixes with "Error: ".
String _formatErrorMessage(Object error) {
  if (error is McpException) {
    return 'Error: ${error.userMessage}';
  }
  if (error is FormatException) {
    return 'Error: Invalid format - ${error.message}';
  }
  return 'Error: $error';
}

/// Creates an error CallToolResult for validation failures.
///
/// Use this for input validation errors where the field and message
/// are known. Does not log to stderr since validation errors are
/// expected user errors, not system failures.
///
/// Example:
/// ```dart
/// if (operation == null) {
///   return validationError('operation', 'operation is required');
/// }
/// ```
CallToolResult validationError(String field, String message) {
  return textResult('Error: $message');
}

/// Creates an error CallToolResult for not found errors.
///
/// Use when a requested resource doesn't exist. Does not log to stderr
/// since not found is an expected condition, not a system failure.
///
/// Example:
/// ```dart
/// final task = db.select('SELECT * FROM tasks WHERE id = ?', [id]);
/// if (task.isEmpty) {
///   return notFoundError('Task', id);
/// }
/// ```
CallToolResult notFoundError(String resourceType, String resourceId) {
  return textResult('Error: $resourceType not found: $resourceId');
}
