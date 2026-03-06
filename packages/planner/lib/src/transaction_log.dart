/// Transaction log data model for planner audit and timeline functionality.
///
/// This module provides the core data structures for tracking changes to
/// tasks and steps, supporting both quick timeline views (via summary field)
/// and detailed audit trails (via changes JSON).
library;

import 'dart:convert';

/// Transaction types representing the kind of operation performed.
enum TransactionType {
  create,
  update,
  delete;

  /// Convert to string for database storage.
  String toDbValue() => name;

  /// Parse from database value.
  static TransactionType fromDbValue(String value) {
    return TransactionType.values.firstWhere(
      (t) => t.name == value,
      orElse: () => throw ArgumentError('Invalid TransactionType: $value'),
    );
  }
}

/// Entity types that can be tracked in the transaction log.
enum EntityType {
  task,
  step,
  item,
  release;

  /// Convert to string for database storage.
  String toDbValue() => name;

  /// Parse from database value.
  static EntityType fromDbValue(String value) {
    return EntityType.values.firstWhere(
      (t) => t.name == value,
      orElse: () => throw ArgumentError('Invalid EntityType: $value'),
    );
  }
}

/// Represents a single transaction log entry.
///
/// Each entry captures:
/// - What changed (entityType, entityId)
/// - What kind of change (transactionType)
/// - When it happened (timestamp)
/// - Human-readable summary for timeline views
/// - Detailed changes JSON for audit trails
class TransactionLogEntry {
  /// Unique identifier for this log entry.
  final String id;

  /// When this transaction occurred.
  final DateTime timestamp;

  /// The type of entity that was modified (task or step).
  final EntityType entityType;

  /// The ID of the entity that was modified.
  final String entityId;

  /// The type of operation performed (create, update, delete).
  final TransactionType transactionType;

  /// Human-readable summary for quick timeline viewing.
  ///
  /// Examples:
  /// - "Task 'Fix bug' created in project 'myapp'"
  /// - "Step 'Write tests' marked as done"
  /// - "Task 'Refactor' status changed from todo to started"
  final String summary;

  /// Detailed changes for audit trail.
  ///
  /// For create operations: All initial field values.
  /// For update operations: Only changed fields with before/after values.
  /// For delete operations: The entity state before deletion.
  ///
  /// Structure:
  /// ```json
  /// {
  ///   "before": {"status": "todo", ...},  // null for create
  ///   "after": {"status": "done", ...}    // null for delete
  /// }
  /// ```
  final Map<String, dynamic>? changes;

  /// Project ID associated with this transaction (for filtering).
  final String? projectId;

  TransactionLogEntry({
    required this.id,
    required this.timestamp,
    required this.entityType,
    required this.entityId,
    required this.transactionType,
    required this.summary,
    this.changes,
    this.projectId,
  });

  /// Create from a database row.
  factory TransactionLogEntry.fromRow(Map<String, dynamic> row) {
    final changesJson = row['changes'] as String?;
    Map<String, dynamic>? changes;
    if (changesJson != null && changesJson.isNotEmpty) {
      changes = jsonDecode(changesJson) as Map<String, dynamic>;
    }

    return TransactionLogEntry(
      id: row['id'] as String,
      timestamp: DateTime.parse(row['created_at'] as String),
      entityType: EntityType.fromDbValue(row['entity_type'] as String),
      entityId: row['entity_id'] as String,
      transactionType: TransactionType.fromDbValue(row['transaction_type'] as String),
      summary: row['summary'] as String,
      changes: changes,
      projectId: row['project_id'] as String?,
    );
  }

  /// Convert to JSON for API responses.
  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'entity_type': entityType.toDbValue(),
    'entity_id': entityId,
    'transaction_type': transactionType.toDbValue(),
    'summary': summary,
    if (changes != null) 'changes': changes,
    if (projectId != null) 'project_id': projectId,
  };

  /// Convert to a minimal JSON for timeline view (no changes detail).
  Map<String, dynamic> toTimelineJson() => {
    'id': id,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'entity_type': entityType.toDbValue(),
    'entity_id': entityId,
    'transaction_type': transactionType.toDbValue(),
    'summary': summary,
    if (projectId != null) 'project_id': projectId,
  };

  @override
  String toString() => 'TransactionLogEntry(id: $id, summary: $summary)';
}

/// Options for querying the transaction log.
class TransactionLogQuery {
  /// Filter by entity type.
  final EntityType? entityType;

  /// Filter by specific entity ID.
  final String? entityId;

  /// Filter by transaction type.
  final TransactionType? transactionType;

  /// Filter by project ID.
  final String? projectId;

  /// Filter entries after this timestamp.
  final DateTime? after;

  /// Filter entries before this timestamp.
  final DateTime? before;

  /// Maximum number of entries to return.
  final int limit;

  /// Offset for pagination.
  final int offset;

  /// Sort order: true for newest first, false for oldest first.
  final bool newestFirst;

  TransactionLogQuery({
    this.entityType,
    this.entityId,
    this.transactionType,
    this.projectId,
    this.after,
    this.before,
    this.limit = 50,
    this.offset = 0,
    this.newestFirst = true,
  });
}
