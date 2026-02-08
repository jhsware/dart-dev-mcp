/// Custom exceptions for MCP server operations.
///
/// This module provides a hierarchy of semantic exception types that enable
/// type-safe error handling with meaningful error messages throughout the
/// MCP server ecosystem.
///
/// Usage:
/// ```dart
/// throw ValidationException('operation', 'operation is required');
/// throw NotFoundException('task', taskId);
/// throw PermissionException('Path not in allowed paths', path: filePath);
/// ```
library;

/// Base exception for all MCP operations.
///
/// All MCP-specific exceptions extend this class, enabling unified
/// catch handling when needed while still allowing specific catches.
abstract class McpException implements Exception {
  /// A user-friendly error message describing what went wrong.
  final String message;

  /// Optional technical details for debugging (logged to stderr).
  final String? details;

  const McpException(this.message, [this.details]);

  @override
  String toString() => details != null ? '$message ($details)' : message;
  
  /// Returns an error message suitable for returning to the user.
  /// Does not include technical details.
  String get userMessage => message;
}

/// Exception thrown when input validation fails.
///
/// Use this for missing required fields, invalid field values,
/// or constraint violations in user input.
///
/// Example:
/// ```dart
/// if (operation == null) {
///   throw ValidationException('operation', 'operation is required');
/// }
/// if (!validStatuses.contains(status)) {
///   throw ValidationException(
///     'status',
///     'Invalid status. Must be one of: ${validStatuses.join(", ")}',
///   );
/// }
/// ```
class ValidationException extends McpException {
  /// The field name that failed validation.
  final String field;

  const ValidationException(this.field, String message, [String? details])
      : super(message, details);

  @override
  String get userMessage => 'Error: $message';
}

/// Exception thrown when a requested resource is not found.
///
/// Use this when looking up entities by ID or path that don't exist.
///
/// Example:
/// ```dart
/// final task = db.select('SELECT * FROM tasks WHERE id = ?', [id]);
/// if (task.isEmpty) {
///   throw NotFoundException('Task', id);
/// }
/// ```
class NotFoundException extends McpException {
  /// The type of resource that wasn't found (e.g., 'Task', 'Step', 'File').
  final String resourceType;

  /// The identifier used to look up the resource.
  final String resourceId;

  NotFoundException(this.resourceType, this.resourceId, [String? details])
      : super('$resourceType not found: $resourceId', details);
}

/// Exception thrown when access to a resource is denied.
///
/// Use this for path restrictions, authorization failures,
/// or other access control violations.
///
/// Example:
/// ```dart
/// if (!isAllowedPath(allowedPaths, absPath)) {
///   throw PermissionException(
///     'Path is outside allowed directories',
///     path: absPath,
///   );
/// }
/// ```
class PermissionException extends McpException {
  /// The path or resource that was denied access.
  final String? path;

  const PermissionException(String message, {this.path, String? details})
      : super(message, details);
}

/// Exception thrown for network or connectivity errors.
///
/// Use this when HTTP requests fail, URLs are unreachable,
/// or network-related operations encounter issues.
///
/// Example:
/// ```dart
/// try {
///   final response = await http.get(uri);
///   if (response.statusCode != 200) {
///     throw NetworkException(
///       'Failed to fetch URL',
///       uri: uri,
///       statusCode: response.statusCode,
///     );
///   }
/// } on SocketException catch (e) {
///   throw NetworkException(
///     'Connection failed',
///     uri: uri,
///     details: e.message,
///   );
/// }
/// ```
class NetworkException extends McpException {
  /// The URI that failed.
  final Uri? uri;

  /// HTTP status code if applicable.
  final int? statusCode;

  const NetworkException(
    String message, {
    this.uri,
    this.statusCode,
    String? details,
  }) : super(message, details);
}

/// Exception thrown for database operation failures.
///
/// Use this for SQLite errors, constraint violations,
/// or other persistence-related failures.
///
/// Example:
/// ```dart
/// try {
///   db.execute('INSERT INTO tasks ...', values);
/// } on SqliteException catch (e) {
///   throw DatabaseException(
///     'Failed to create task',
///     errorCode: e.extendedResultCode,
///     details: e.message,
///   );
/// }
/// ```
class DatabaseException extends McpException {
  /// SQLite error code if applicable.
  final int? errorCode;

  const DatabaseException(
    String message, {
    this.errorCode,
    String? details,
  }) : super(message, details);
}

/// Exception thrown when an operation fails for reasons other than
/// validation, not found, permission, network, or database errors.
///
/// Use this as a catch-all for operation-specific failures that
/// don't fit other categories.
///
/// Example:
/// ```dart
/// final result = await Process.run('git', args);
/// if (result.exitCode != 0) {
///   throw OperationException(
///     'Git command failed',
///     exitCode: result.exitCode,
///     details: result.stderr as String,
///   );
/// }
/// ```
class OperationException extends McpException {
  /// Process exit code if applicable.
  final int? exitCode;

  /// The operation that failed.
  final String? operation;

  const OperationException(
    String message, {
    this.exitCode,
    this.operation,
    String? details,
  }) : super(message, details);
}
