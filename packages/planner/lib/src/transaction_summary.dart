/// Summary generator and diff calculator for transaction logging.
///
/// Provides helper functions to create human-readable summaries for timeline
/// views and calculate minimal diffs for audit trail storage.
library;

import 'transaction_log.dart';

/// Generate a human-readable summary for timeline display.
///
/// Creates concise summaries like:
/// - "Task 'Fix bug' created in project 'myapp'"
/// - "Task 'Fix bug' status changed to done"
/// - "Step 'Write tests' added to task"
/// - "Task 'Fix bug' deleted"
String generateSummary({
  required TransactionType transactionType,
  required EntityType entityType,
  required String entityTitle,
  String? projectId,
  String? taskTitle,
  Map<String, dynamic>? changes,
}) {
  final entityName = switch (entityType) {
    EntityType.task => 'Task',
    EntityType.step => 'Step',
    EntityType.item => 'Item',
    EntityType.release => 'Release',
  };
  final truncatedTitle = _truncateTitle(entityTitle);

  switch (transactionType) {
    case TransactionType.create:
      if (entityType == EntityType.task || entityType == EntityType.item || entityType == EntityType.release) {
        return projectId != null
            ? "$entityName '$truncatedTitle' created in project '$projectId'"
            : "$entityName '$truncatedTitle' created";
      } else {
        return taskTitle != null
            ? "$entityName '$truncatedTitle' added to task '$taskTitle'"
            : "$entityName '$truncatedTitle' created";
      }

    case TransactionType.update:
      final changeDesc = _describeChanges(changes);
      return changeDesc != null
          ? "$entityName '$truncatedTitle' $changeDesc"
          : "$entityName '$truncatedTitle' updated";

    case TransactionType.delete:
      return "$entityName '$truncatedTitle' deleted";
  }
}

/// Truncate title for summary display.
String _truncateTitle(String title, {int maxLength = 50}) {
  if (title.length <= maxLength) return title;
  return '${title.substring(0, maxLength - 3)}...';
}

/// Describe changes in human-readable form.
String? _describeChanges(Map<String, dynamic>? changes) {
  if (changes == null) return null;

  final after = changes['after'] as Map<String, dynamic>?;
  final before = changes['before'] as Map<String, dynamic>?;

  if (after == null) return null;

  // Priority order for describing changes
  if (after.containsKey('status')) {
    final newStatus = after['status'];
    final oldStatus = before?['status'];
    if (oldStatus != null) {
      return "status changed from $oldStatus to $newStatus";
    }
    return "status changed to $newStatus";
  }

  if (after.containsKey('type')) {
    final newType = after['type'];
    final oldType = before?['type'];
    if (oldType != null) {
      return "type changed from $oldType to $newType";
    }
    return "type changed to $newType";
  }

  if (after.containsKey('title')) {
    return 'title updated';
  }

  if (after.containsKey('details')) {
    return 'details updated';
  }

  if (after.containsKey('notes')) {
    return 'notes updated';
  }

  if (after.containsKey('memory')) {
    return 'memory updated';
  }

  if (after.containsKey('project_id')) {
    return "moved to project '${after['project_id']}'";
  }

  // Generic description for other changes
  final changedFields = after.keys.toList();
  if (changedFields.length == 1) {
    return '${changedFields.first} updated';
  } else if (changedFields.length <= 3) {
    return '${changedFields.join(", ")} updated';
  }
  return 'multiple fields updated';
}

/// Calculate minimal diff for audit trail storage.
///
/// For create operations: stores all initial field values.
/// For update operations: stores only changed fields with before/after values.
/// For delete operations: stores the final state before deletion.
///
/// Returns a map with structure:
/// ```json
/// {
///   "before": {"field": "old_value", ...},  // null for create
///   "after": {"field": "new_value", ...}    // null for delete
/// }
/// ```
Map<String, dynamic> calculateChanges({
  required TransactionType transactionType,
  Map<String, dynamic>? before,
  Map<String, dynamic>? after,
}) {
  switch (transactionType) {
    case TransactionType.create:
      // For create, store all initial values
      return {
        'before': null,
        'after': _cleanEntityData(after),
      };

    case TransactionType.update:
      // For update, store only changed fields
      return _calculateDiff(before, after);

    case TransactionType.delete:
      // For delete, store final state for potential recovery
      return {
        'before': _cleanEntityData(before),
        'after': null,
      };
  }
}

/// Calculate diff between before and after states.
///
/// Only includes fields that actually changed.
Map<String, dynamic> _calculateDiff(
  Map<String, dynamic>? before,
  Map<String, dynamic>? after,
) {
  if (before == null || after == null) {
    return {
      'before': _cleanEntityData(before),
      'after': _cleanEntityData(after),
    };
  }

  final changedBefore = <String, dynamic>{};
  final changedAfter = <String, dynamic>{};

  // Check all keys in after for changes
  for (final key in after.keys) {
    // Skip metadata fields that are always expected to change
    if (key == 'updated_at') continue;

    final beforeValue = before[key];
    final afterValue = after[key];

    if (beforeValue != afterValue) {
      changedBefore[key] = beforeValue;
      changedAfter[key] = afterValue;
    }
  }

  // Check for removed keys (in before but not in after)
  for (final key in before.keys) {
    if (!after.containsKey(key) && key != 'updated_at') {
      changedBefore[key] = before[key];
      changedAfter[key] = null;
    }
  }

  return {
    'before': changedBefore.isEmpty ? null : changedBefore,
    'after': changedAfter.isEmpty ? null : changedAfter,
  };
}

/// Clean entity data for storage.
///
/// Removes internal fields that shouldn't be stored in audit logs.
Map<String, dynamic>? _cleanEntityData(Map<String, dynamic>? data) {
  if (data == null) return null;

  // Create a copy to avoid modifying original
  final cleaned = Map<String, dynamic>.from(data);

  // Keep most fields but could filter out sensitive data here if needed
  return cleaned.isEmpty ? null : cleaned;
}

/// Helper to create a loggable entity from task data.
Map<String, dynamic> taskToLoggable(Map<String, dynamic> task) {
  return {
    'id': task['id'],
    'project_id': task['project_id'],
    'title': task['title'],
    'details': task['details'],
    'status': task['status'],
    'memory': task['memory'],
    'created_at': task['created_at'],
    'updated_at': task['updated_at'],
  };
}

/// Helper to create a loggable entity from step data.
Map<String, dynamic> stepToLoggable(Map<String, dynamic> step) {
  return {
    'id': step['id'],
    'task_id': step['task_id'],
    'title': step['title'],
    'details': step['details'],
    'status': step['status'],
    'sub_task_id': step['sub_task_id'],
    'created_at': step['created_at'],
    'updated_at': step['updated_at'],
  };
}

/// Helper to create a loggable entity from item data.
Map<String, dynamic> itemToLoggable(Map<String, dynamic> item) {
  return {
    'id': item['id'],
    'project_id': item['project_id'],
    'title': item['title'],
    'details': item['details'],
    'type': item['type'],
    'status': item['status'],
    'created_at': item['created_at'],
    'updated_at': item['updated_at'],
  };
}

/// Helper to create a loggable entity from release data.
Map<String, dynamic> releaseToLoggable(Map<String, dynamic> release) {
  return {
    'id': release['id'],
    'project_id': release['project_id'],
    'title': release['title'],
    'notes': release['notes'],
    'status': release['status'],
    'release_date': release['release_date'],
    'created_at': release['created_at'],
    'updated_at': release['updated_at'],
  };
}
