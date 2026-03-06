import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'planner.dart';

/// Timeline and audit trail operations handler.
class TimelineOperations {
  final TransactionLogRepository transactionLogRepository;

  TimelineOperations({
    required this.transactionLogRepository,
  });

  /// Get recent activity timeline with optional filters.
  CallToolResult getTimeline(Map<String, dynamic>? args) {
    final limit = (args?['limit'] as int?) ?? 20;
    final projectId = args?['project_id'] as String?;
    final entityTypeStr = args?['entity_type'] as String?;
    final beforeStr = args?['before'] as String?;
    final afterStr = args?['after'] as String?;

    // Parse entity type if provided
    EntityType? entityType;
    if (entityTypeStr != null) {
      try {
        entityType = EntityType.fromDbValue(entityTypeStr);
      } catch (e) {
        return validationError(
            'entity_type', "Invalid entity_type. Must be 'task' or 'step'");
      }
    }

    // Parse datetime filters
    DateTime? before;
    DateTime? after;

    if (beforeStr != null) {
      try {
        before = DateTime.parse(beforeStr);
      } catch (e) {
        return validationError(
            'before', 'Invalid before datetime format. Use ISO 8601 format.');
      }
    }

    if (afterStr != null) {
      try {
        after = DateTime.parse(afterStr);
      } catch (e) {
        return validationError(
            'after', 'Invalid after datetime format. Use ISO 8601 format.');
      }
    }

    // Build query
    final query = TransactionLogQuery(
      entityType: entityType,
      before: before,
      after: after,
      limit: limit,
      newestFirst: true,
    );

    // Get timeline entries
    final entries = transactionLogRepository.getTimeline(query);

    // Format for output (timeline view - no detailed changes)
    final timeline = entries.map((entry) => entry.toTimelineJson()).toList();

    return jsonResult({
      'timeline': timeline,
      'count': timeline.length,
      'filters': {
        // ignore: use_null_aware_elements
        if (projectId != null) 'project_id': projectId,
        // ignore: use_null_aware_elements
        if (entityTypeStr != null) 'entity_type': entityTypeStr,
        // ignore: use_null_aware_elements
        if (beforeStr != null) 'before': beforeStr,
        // ignore: use_null_aware_elements
        if (afterStr != null) 'after': afterStr,
        'limit': limit,
      },
    });
  }

  /// Get detailed change history for a specific entity.
  CallToolResult getAuditTrail(Map<String, dynamic>? args) {
    final entityTypeStr = args?['entity_type'] as String?;
    final entityId = args?['id'] as String?;
    final limit = (args?['limit'] as int?) ?? 100;

    // Validate required parameters
    if (requireString(entityTypeStr, 'entity_type') case final error?) {
      return error;
    }

    if (requireString(entityId, 'id') case final error?) {
      return error;
    }

    // Parse entity type
    EntityType entityType;
    try {
      entityType = EntityType.fromDbValue(entityTypeStr!);
    } catch (e) {
      return validationError(
          'entity_type', "Invalid entity_type. Must be 'task' or 'step'");
    }

    // Get audit trail entries
    final entries = transactionLogRepository.getAuditTrail(
      entityType: entityType,
      entityId: entityId!,
      limit: limit,
      newestFirst: true,
    );

    // Format for output (full details including changes)
    final auditTrail = entries.map((entry) => entry.toJson()).toList();

    return jsonResult({
      'entity_type': entityTypeStr,
      'entity_id': entityId,
      'audit_trail': auditTrail,
      'count': auditTrail.length,
    });
  }
}
