/// Input validation helpers for MCP server operations.
///
/// These helpers provide consistent validation with early-return pattern
/// and standardized error messages across all MCP servers.
///
/// Usage:
/// ```dart
/// CallToolResult _handleOperation(Map<String, dynamic>? args) {
///   final operation = args?['operation'] as String?;
///   if (requireString(operation, 'operation') case final error?) {
///     return error;
///   }
///   
///   final status = args?['status'] as String?;
///   if (requireOneOf(status, 'status', validStatuses) case final error?) {
///     return error;
///   }
///   
///   // Continue with validated inputs...
/// }
/// ```
library;

import 'package:mcp_dart/mcp_dart.dart';

import 'result_helpers.dart';

/// Validates that a required string parameter is present and non-empty.
///
/// Returns an error result if the value is null or empty, otherwise null.
///
/// Example:
/// ```dart
/// final id = args?['id'] as String?;
/// if (requireString(id, 'id') case final error?) {
///   return error;
/// }
/// ```
CallToolResult? requireString(String? value, String fieldName) {
  if (value == null || value.isEmpty) {
    return validationError(fieldName, '$fieldName is required');
  }
  return null;
}

/// Validates that an optional string value is one of the allowed values.
///
/// Returns null if value is null (optional field not provided) or if valid.
/// Returns an error result if value is provided but not in validValues.
///
/// Example:
/// ```dart
/// final status = args?['status'] as String?;
/// if (requireOneOf(status, 'status', ['todo', 'done']) case final error?) {
///   return error;
/// }
/// ```
CallToolResult? requireOneOf(
  String? value,
  String fieldName,
  List<String> validValues,
) {
  if (value == null) return null; // Optional field not provided
  if (!validValues.contains(value)) {
    return validationError(
      fieldName,
      'Invalid $fieldName. Must be one of: ${validValues.join(", ")}',
    );
  }
  return null;
}

/// Validates that a required string value is one of the allowed values.
///
/// Returns an error result if value is null/empty or not in validValues.
///
/// Example:
/// ```dart
/// final operation = args?['operation'] as String?;
/// if (requireStringOneOf(operation, 'operation', validOperations) case final error?) {
///   return error;
/// }
/// ```
CallToolResult? requireStringOneOf(
  String? value,
  String fieldName,
  List<String> validValues,
) {
  if (requireString(value, fieldName) case final error?) {
    return error;
  }
  if (!validValues.contains(value)) {
    return validationError(
      fieldName,
      'Invalid $fieldName. Must be one of: ${validValues.join(", ")}',
    );
  }
  return null;
}

/// Validates that an integer value is within bounds.
///
/// Returns null if value is null (optional field not provided) or if valid.
/// Returns an error result if value is out of bounds.
///
/// Example:
/// ```dart
/// final limit = args?['limit'] as int?;
/// if (requireIntInRange(limit, 'limit', min: 1, max: 100) case final error?) {
///   return error;
/// }
/// ```
CallToolResult? requireIntInRange(
  int? value,
  String fieldName, {
  int? min,
  int? max,
}) {
  if (value == null) return null; // Optional field not provided
  
  if (min != null && value < min) {
    return validationError(fieldName, '$fieldName must be at least $min');
  }
  if (max != null && value > max) {
    return validationError(fieldName, '$fieldName must be at most $max');
  }
  return null;
}

/// Validates that a required integer value is present.
///
/// Returns an error result if value is null.
///
/// Example:
/// ```dart
/// final lineNumber = args?['line'] as int?;
/// if (requireInt(lineNumber, 'line') case final error?) {
///   return error;
/// }
/// ```
CallToolResult? requireInt(int? value, String fieldName) {
  if (value == null) {
    return validationError(fieldName, '$fieldName is required');
  }
  return null;
}

/// Validates that a required positive integer value is present.
///
/// Returns an error result if value is null or not positive.
///
/// Example:
/// ```dart
/// final count = args?['count'] as int?;
/// if (requirePositiveInt(count, 'count') case final error?) {
///   return error;
/// }
/// ```
CallToolResult? requirePositiveInt(int? value, String fieldName) {
  if (value == null) {
    return validationError(fieldName, '$fieldName is required');
  }
  if (value <= 0) {
    return validationError(fieldName, '$fieldName must be positive');
  }
  return null;
}
