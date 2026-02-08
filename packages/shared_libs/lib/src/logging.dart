/// Logging utilities for MCP server operations.
///
/// Provides consistent logging to stderr with timestamps, operation context,
/// and stack traces for debugging.
library;

import 'dart:convert';
import 'dart:io';

import 'exceptions.dart';

/// Log an error with full context to stderr.
///
/// Logs the error with timestamp, operation name, optional stack trace,
/// and optional context information. This provides consistent error
/// logging across all MCP servers.
///
/// Example:
/// ```dart
/// try {
///   await someOperation();
/// } catch (e, stackTrace) {
///   logError('planner:add-task', e, stackTrace, {
///     'project_id': projectId,
///     'title': title,
///   });
///   return textResult('Error: $e');
/// }
/// ```
void logError(
  String operation,
  Object error, [
  StackTrace? stackTrace,
  Map<String, dynamic>? context,
]) {
  final timestamp = DateTime.now().toIso8601String();
  final buffer = StringBuffer();
  
  buffer.write('[$timestamp] ERROR in $operation: $error');
  
  // Add exception details if available
  if (error is McpException && error.details != null) {
    buffer.write(' (${error.details})');
  }
  
  // Add context if provided
  if (context != null && context.isNotEmpty) {
    buffer.write(' context=${jsonEncode(context)}');
  }
  
  stderr.writeln(buffer);
  
  // Include stack trace for non-MCP exceptions or when explicitly provided
  if (stackTrace != null && error is! McpException) {
    stderr.writeln('Stack trace:');
    stderr.writeln(stackTrace);
  }
}

/// Log a warning message to stderr.
///
/// Use for non-critical issues that don't prevent operation completion
/// but should be noted for debugging or operational awareness.
///
/// Example:
/// ```dart
/// if (!await pubspecFile.exists()) {
///   logWarning('dart-runner', 'No pubspec.yaml found - may not be a Dart project');
/// }
/// ```
void logWarning(String operation, String message) {
  final timestamp = DateTime.now().toIso8601String();
  stderr.writeln('[$timestamp] WARN in $operation: $message');
}

/// Log an informational message to stderr.
///
/// Use for important operational events like startup, shutdown,
/// or significant state changes.
///
/// Example:
/// ```dart
/// logInfo('planner', 'Database initialized at $dbPath');
/// ```
void logInfo(String operation, String message) {
  final timestamp = DateTime.now().toIso8601String();
  stderr.writeln('[$timestamp] INFO in $operation: $message');
}

/// Log a debug message to stderr.
///
/// Use for detailed debugging information. Consider making this
/// conditional on a debug flag in production.
///
/// Example:
/// ```dart
/// logDebug('git', 'Running command: git ${args.join(" ")}');
/// ```
void logDebug(String operation, String message) {
  final timestamp = DateTime.now().toIso8601String();
  stderr.writeln('[$timestamp] DEBUG in $operation: $message');
}
