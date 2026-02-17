import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'planner.dart';

/// Valid task statuses.
const validTaskStatuses = ['backlog', 'todo', 'draft', 'started', 'canceled', 'done', 'merged'];

/// Valid step statuses.
const validStepStatuses = ['todo', 'started', 'canceled', 'done'];

final _uuid = Uuid();

/// Normalizes legacy step statuses for backward compatibility.
/// - 'merged' → 'done'
/// - 'draft' → 'todo'
String normalizeStepStatus(String status) {
  switch (status) {
    case 'merged':
      return 'done';
    case 'draft':
      return 'todo';
    default:
      return status;
  }
}

/// Task operations handler.
class TaskOperations {
  final Database database;
  final TransactionLogRepository transactionLogRepository;

  TaskOperations({
    required this.database,
    required this.transactionLogRepository,
  });

  /// Add a new task.
  CallToolResult addTask(Map<String, dynamic>? args) {
    final projectId = args?['project_id'] as String?;
    final title = args?['title'] as String?;
    final details = args?['details'] as String?;
    final status = args?['status'] as String? ?? 'todo';
    final memory = args?['memory'] as String?;

    if (requireString(projectId, 'project_id') case final error?) {
      return error;
    }

    if (requireString(title, 'title') case final error?) {
      return error;
    }

    if (requireOneOf(status, 'status', validTaskStatuses) case final error?) {
      return error;
    }

    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();

    final taskData = {
      'id': id,
      'project_id': projectId,
      'title': title,
      'details': details,
      'status': status,
      'memory': memory,
      'created_at': now,
      'updated_at': now,
    };

    // Wrap INSERT and transaction log in atomic transaction with retry
    withRetryTransactionSync(database, () {
      database.execute('''
        INSERT INTO tasks (id, project_id, title, details, status, memory, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''', [id, projectId, title, details, status, memory, now, now]);

      transactionLogRepository.log(
        entityType: EntityType.task,
        entityId: id,
        transactionType: TransactionType.create,
        summary: generateSummary(
          transactionType: TransactionType.create,
          entityType: EntityType.task,
          entityTitle: title!,
          projectId: projectId,
        ),
        changes: calculateChanges(
          transactionType: TransactionType.create,
          after: taskData,
        ),
        projectId: projectId,
      );
    });

    return jsonResult({
      'success': true,
      'message': 'Task created',
      'task': taskData,
    });
  }

  /// Show task details with steps.
  CallToolResult showTask(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    final taskResult = database.select('SELECT * FROM tasks WHERE id = ?', [id]);

    if (taskResult.isEmpty) {
      return notFoundError('Task', id!);
    }

    final task = taskResult.first;

    // Get steps for this task, ordered by sort_order with fallback to created_at
    final stepsResult = database.select(
        'SELECT id, title, status, sub_task_id FROM steps WHERE task_id = ? ORDER BY COALESCE(sort_order, 9999999), created_at',
        [id]);

    final steps = stepsResult
        .map((row) => {
              'id': row['id'],
              'title': row['title'],
              'status': normalizeStepStatus(row['status'] as String),
              'sub_task_id': row['sub_task_id'],
            })
        .toList();

    return jsonResult({
      'id': task['id'],
      'project_id': task['project_id'],
      'title': task['title'],
      'details': task['details'],
      'status': task['status'],
      'created_at': task['created_at'],
      'updated_at': task['updated_at'],
      'steps': steps,
    });
  }

  /// Update task properties.
  CallToolResult updateTask(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    // Get task before update for diff calculation
    final existingResult =
        database.select('SELECT * FROM tasks WHERE id = ?', [id]);
    if (existingResult.isEmpty) {
      return notFoundError('Task', id!);
    }

    final before = taskToLoggable(Map<String, dynamic>.from(existingResult.first));

    final updates = <String>[];
    final values = <Object?>[];

    if (args?.containsKey('project_id') == true) {
      updates.add('project_id = ?');
      values.add(args!['project_id']);
    }

    if (args?.containsKey('title') == true) {
      updates.add('title = ?');
      values.add(args!['title']);
    }

    if (args?.containsKey('details') == true) {
      updates.add('details = ?');
      values.add(args!['details']);
    }

    if (args?.containsKey('status') == true) {
      final status = args!['status'] as String;
      if (requireOneOf(status, 'status', validTaskStatuses) case final error?) {
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
          'UPDATE tasks SET ${updates.join(", ")} WHERE id = ?', values);

      // Get task after update
      final afterResult =
          database.select('SELECT * FROM tasks WHERE id = ?', [id]);
      final after = taskToLoggable(Map<String, dynamic>.from(afterResult.first));

      // Calculate changes for audit
      final changes = calculateChanges(
        transactionType: TransactionType.update,
        before: before,
        after: after,
      );

      // Log the transaction
      transactionLogRepository.log(
        entityType: EntityType.task,
        entityId: id!,
        transactionType: TransactionType.update,
        summary: generateSummary(
          transactionType: TransactionType.update,
          entityType: EntityType.task,
          entityTitle: after['title'] as String,
          projectId: after['project_id'] as String?,
          changes: changes,
        ),
        changes: changes,
        projectId: after['project_id'] as String?,
      );
    });

    // Return updated task
    return showTask(args);
  }

  /// Show task memory/notes.
  CallToolResult showTaskMemory(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    final result =
        database.select('SELECT id, title, memory FROM tasks WHERE id = ?', [id]);

    if (result.isEmpty) {
      return notFoundError('Task', id!);
    }

    final task = result.first;
    final memory = task['memory'] as String?;

    return jsonResult({
      'id': task['id'],
      'title': task['title'],
      'memory': memory ?? '',
    });
  }

  /// Update task memory/notes.
  CallToolResult updateTaskMemory(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;
    final memory = args?['memory'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    // Get task before update for diff calculation
    final existingResult =
        database.select('SELECT * FROM tasks WHERE id = ?', [id]);
    if (existingResult.isEmpty) {
      return notFoundError('Task', id!);
    }

    final before = taskToLoggable(Map<String, dynamic>.from(existingResult.first));

    final now = DateTime.now().toUtc().toIso8601String();

    // Wrap UPDATE and transaction log in atomic transaction with retry
    withRetryTransactionSync(database, () {
      database.execute(
          'UPDATE tasks SET memory = ?, updated_at = ? WHERE id = ?',
          [memory, now, id]);

      // Get task after update
      final afterResult =
          database.select('SELECT * FROM tasks WHERE id = ?', [id]);
      final after = taskToLoggable(Map<String, dynamic>.from(afterResult.first));

      // Calculate changes for audit
      final changes = calculateChanges(
        transactionType: TransactionType.update,
        before: before,
        after: after,
      );

      // Log the transaction
      transactionLogRepository.log(
        entityType: EntityType.task,
        entityId: id!,
        transactionType: TransactionType.update,
        summary: generateSummary(
          transactionType: TransactionType.update,
          entityType: EntityType.task,
          entityTitle: after['title'] as String,
          projectId: after['project_id'] as String?,
          changes: changes,
        ),
        changes: changes,
        projectId: after['project_id'] as String?,
      );
    });

    return jsonResult({
      'success': true,
      'message': 'Task memory updated',
      'id': id,
    });
  }

  /// List tasks with optional filters.
  CallToolResult listTasks(Map<String, dynamic>? args) {
    final projectId = args?['project_id'] as String?;
    final status = args?['status'] as String?;

    // Validate status if provided
    if (status != null && status.isNotEmpty) {
      if (requireOneOf(status, 'status', validTaskStatuses) case final error?) {
        return error;
      }
    }

    // Build query with optional filters
    final conditions = <String>[];
    final values = <Object?>[];

    if (projectId != null && projectId.isNotEmpty) {
      conditions.add('t.project_id = ?');
      values.add(projectId);
    }

    if (status != null && status.isNotEmpty) {
      conditions.add('t.status = ?');
      values.add(status);
    }

    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(" AND ")}';

    // Query with step count subquery
    final query = '''
      SELECT 
        t.id,
        t.project_id,
        t.title,
        t.status,
        t.created_at,
        t.updated_at,
        (SELECT COUNT(*) FROM steps s WHERE s.task_id = t.id) as step_count
      FROM tasks t
      $whereClause
      ORDER BY t.updated_at DESC
    ''';

    final result = database.select(query, values);

    final tasks = result
        .map((row) => {
              'id': row['id'],
              'project_id': row['project_id'],
              'title': row['title'],
              'status': row['status'],
              'step_count': row['step_count'],
              'created_at': row['created_at'],
              'updated_at': row['updated_at'],
            })
        .toList();

    return jsonResult({
      'tasks': tasks,
      'count': tasks.length,
      'filters': {
        // ignore: use_null_aware_elements
        if (projectId != null) 'project_id': projectId,
        // ignore: use_null_aware_elements
        if (status != null) 'status': status,
      },
    });
  }
}
