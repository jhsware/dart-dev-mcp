import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'planner.dart';

final _uuid = Uuid();


/// Step operations handler.
class StepOperations {
  final Database database;
  final TransactionLogRepository transactionLogRepository;

  StepOperations({
    required this.database,
    required this.transactionLogRepository,
  });

  /// Add a new step to a task.
  CallToolResult addStep(Map<String, dynamic>? args) {
    final taskId = args?['task_id'] as String?;
    final title = args?['title'] as String?;
    final details = args?['details'] as String?;
    // Normalize legacy statuses for backward compatibility
    final status = normalizeStepStatus(args?['status'] as String? ?? 'todo');

    if (requireString(taskId, 'task_id') case final error?) {
      return error;
    }

    if (requireString(title, 'title') case final error?) {
      return error;
    }

    if (requireOneOf(status, 'status', validStepStatuses) case final error?) {
      return error;
    }

    // Check task exists and get task info for logging
    final taskResult = database.select(
        'SELECT id, title, project_id FROM tasks WHERE id = ?', [taskId]);
    if (taskResult.isEmpty) {
      return notFoundError('Task', taskId!);
    }
    final taskInfo = taskResult.first;

    // Calculate sort_order for the new step (append to end)
    final countResult = database
        .select('SELECT COUNT(*) as count FROM steps WHERE task_id = ?', [taskId]);
    final sortOrder = (countResult.first['count'] as int) + 1;

    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();

    final stepData = {
      'id': id,
      'task_id': taskId,
      'title': title,
      'details': details,
      'status': status,
      'sort_order': sortOrder,
      'created_at': now,
      'updated_at': now,
    };

    // Wrap INSERT and transaction log in atomic transaction with retry
    withRetryTransactionSync(database, () {
      database.execute('''
        INSERT INTO steps (id, task_id, title, details, status, sort_order, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''', [id, taskId, title, details, status, sortOrder, now, now]);

      transactionLogRepository.log(
        entityType: EntityType.step,
        entityId: id,
        transactionType: TransactionType.create,
        summary: generateSummary(
          transactionType: TransactionType.create,
          entityType: EntityType.step,
          entityTitle: title!,
          taskTitle: taskInfo['title'] as String?,
        ),
        changes: calculateChanges(
          transactionType: TransactionType.create,
          after: stepData,
        ),
        projectId: taskInfo['project_id'] as String?,
      );
    });

    return jsonResult({
      'success': true,
      'message': 'Step created',
      'step': stepData,
    });
  }

  /// Show step details.
  CallToolResult showStep(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    final result = database.select('SELECT * FROM steps WHERE id = ?', [id]);

    if (result.isEmpty) {
      return notFoundError('Step', id!);
    }

    final step = result.first;

    return jsonResult({
      'id': step['id'],
      'task_id': step['task_id'],
      'title': step['title'],
      'details': step['details'],
      'status': normalizeStepStatus(step['status'] as String),
      'created_at': step['created_at'],
      'updated_at': step['updated_at'],
    });
  }

  /// Update step properties.
  CallToolResult updateStep(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    // Get step before update for diff calculation
    final existingResult = database.select('''
      SELECT s.*, t.title as task_title, t.project_id
      FROM steps s
      JOIN tasks t ON s.task_id = t.id
      WHERE s.id = ?
    ''', [id]);
    if (existingResult.isEmpty) {
      return notFoundError('Step', id!);
    }

    final existingRow = existingResult.first;
    final before = stepToLoggable(Map<String, dynamic>.from(existingRow));
    final projectId = existingRow['project_id'] as String?;

    final updates = <String>[];
    final values = <Object?>[];

    if (args?.containsKey('title') == true) {
      updates.add('title = ?');
      values.add(args!['title']);
    }

    if (args?.containsKey('details') == true) {
      updates.add('details = ?');
      values.add(args!['details']);
    }

    if (args?.containsKey('status') == true) {
      // Normalize legacy statuses for backward compatibility
      final status = normalizeStepStatus(args!['status'] as String);
      if (requireOneOf(status, 'status', validStepStatuses) case final error?) {
        return error;
      }
      updates.add('status = ?');
      values.add(status);
    }

    if (updates.isEmpty) {
      return validationError('fields', 'No fields to update');
    }

    final now = DateTime.now().toUtc().toIso8601String();
    updates.add('updated_at = ?');
    values.add(now);
    values.add(id);

    // Wrap UPDATE and transaction log in atomic transaction with retry
    withRetryTransactionSync(database, () {
      database.execute(
          'UPDATE steps SET ${updates.join(", ")} WHERE id = ?', values);

      // Get step after update
      final afterResult =
          database.select('SELECT * FROM steps WHERE id = ?', [id]);
      final after = stepToLoggable(Map<String, dynamic>.from(afterResult.first));

      // Calculate changes for audit
      final changes = calculateChanges(
        transactionType: TransactionType.update,
        before: before,
        after: after,
      );

      // Log the transaction
      transactionLogRepository.log(
        entityType: EntityType.step,
        entityId: id!,
        transactionType: TransactionType.update,
        summary: generateSummary(
          transactionType: TransactionType.update,
          entityType: EntityType.step,
          entityTitle: after['title'] as String,
          changes: changes,
        ),
        changes: changes,
        projectId: projectId,
      );
    });

    // Return updated step
    return showStep(args);
  }
}
