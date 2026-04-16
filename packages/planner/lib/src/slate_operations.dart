import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'planner.dart';

/// Valid slate statuses.
const validSlateStatuses = ['draft', 'todo', 'started', 'done', 'released'];

final _uuid = Uuid();

/// Slate operations handler for backlog slates.
class SlateOperations {
  final Database database;
  final TransactionLogRepository transactionLogRepository;

  SlateOperations({
    required this.database,
    required this.transactionLogRepository,
  });

  /// Add a new slate.
  CallToolResult addSlate(Map<String, dynamic>? args) {
    final title = args?['title'] as String?;
    final notes = args?['notes'] as String?;
    final status = args?['status'] as String? ?? 'draft';
    final slateDate = args?['release_date'] as String?;

    if (requireString(title, 'title') case final error?) {
      return error;
    }

    if (requireOneOf(status, 'status', validSlateStatuses)
        case final error?) {
      return error;
    }

    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();

    final slateData = {
      'id': id,
      'title': title,
      'notes': notes,
      'status': status,
      'slate_date': slateDate,
      'created_at': now,
      'updated_at': now,
    };

    withRetryTransactionSync(database, () {
      database.execute('''
        INSERT INTO slates (id, project_id, title, notes, status, slate_date, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''', [id, '', title, notes, status, slateDate, now, now]);

      transactionLogRepository.log(
        entityType: EntityType.slate,
        entityId: id,
        transactionType: TransactionType.create,
        summary: generateSummary(
          transactionType: TransactionType.create,
          entityType: EntityType.slate,
          entityTitle: title!,
        ),
        changes: calculateChanges(
          transactionType: TransactionType.create,
          after: slateData,
        ),
      );
    });

    return jsonResult({
      'success': true,
      'message': 'Slate created',
      'slate': slateData,
    });
  }

  /// Show slate details with assigned items.
  CallToolResult showSlate(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    final slateResult =
        database.select('SELECT * FROM slates WHERE id = ?', [id]);

    if (slateResult.isEmpty) {
      return notFoundError('Slate', id!);
    }

    final slate = slateResult.first;

    // Get items assigned to this slate via slate_items junction
    final itemsResult = database.select('''
      SELECT i.id, i.title, i.type, i.status, ri.added_at
      FROM items i
      INNER JOIN slate_items ri ON ri.item_id = i.id
      WHERE ri.slate_id = ?
      ORDER BY ri.added_at DESC
    ''', [id]);

    final items = itemsResult
        .map((row) => {
              'id': row['id'],
              'title': row['title'],
              'type': row['type'],
              'status': row['status'],
              'added_at': row['added_at'],
            })
        .toList();

    return jsonResult({
      'id': slate['id'],
      'title': slate['title'],
      'notes': slate['notes'],
      'status': slate['status'],
      'slate_date': slate['slate_date'],
      'created_at': slate['created_at'],
      'updated_at': slate['updated_at'],
      'items': items,
    });
  }

  /// Update slate properties.
  CallToolResult updateSlate(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    final existingResult =
        database.select('SELECT * FROM slates WHERE id = ?', [id]);
    if (existingResult.isEmpty) {
      return notFoundError('Slate', id!);
    }

    final existing = Map<String, dynamic>.from(existingResult.first);
    final before =
        slateToLoggable(existing);

    final updates = <String>[];
    final values = <Object?>[];
    final changedFields = <MapEntry<String, MapEntry<String?, String?>>>[];

    if (args?.containsKey('title') == true) {
      final newTitle = args!['title'] as String?;
      if (existing['title'] != newTitle) {
        changedFields.add(MapEntry(
            'title', MapEntry(existing['title'] as String?, newTitle)));
      }
      updates.add('title = ?');
      values.add(newTitle);
    }

    if (args?.containsKey('notes') == true) {
      final newNotes = args!['notes'] as String?;
      if (existing['notes'] != newNotes) {
        changedFields.add(MapEntry(
            'notes', MapEntry(existing['notes'] as String?, newNotes)));
      }
      updates.add('notes = ?');
      values.add(newNotes);
    }

    if (args?.containsKey('status') == true) {
      final newStatus = args!['status'] as String;
      if (requireOneOf(newStatus, 'status', validSlateStatuses)
          case final error?) {
        return error;
      }
      if (existing['status'] != newStatus) {
        changedFields.add(MapEntry(
            'status', MapEntry(existing['status'] as String?, newStatus)));
      }
      updates.add('status = ?');
      values.add(newStatus);
    }

    if (args?.containsKey('release_date') == true) {
      final newDate = args!['release_date'] as String?;
      if (existing['slate_date'] != newDate) {
        changedFields.add(MapEntry(
            'slate_date', MapEntry(existing['slate_date'] as String?, newDate)));
      }
      updates.add('slate_date = ?');
      values.add(newDate);
    }

    if (updates.isEmpty) {
      return validationError('fields', 'No fields to update');
    }

    final now = DateTime.now().toUtc().toIso8601String();
    updates.add('updated_at = ?');
    values.add(now);
    values.add(id);

    withRetryTransactionSync(database, () {
      database.execute(
          'UPDATE slates SET ${updates.join(", ")} WHERE id = ?', values);

      // Insert slate_history rows for each changed field
      for (final change in changedFields) {
        final historyId = _uuid.v4();
        database.execute('''
          INSERT INTO slate_history (id, slate_id, field_name, old_value, new_value, changed_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [historyId, id, change.key, change.value.key, change.value.value, now]);
      }

      final afterResult =
          database.select('SELECT * FROM slates WHERE id = ?', [id]);
      final after =
          slateToLoggable(Map<String, dynamic>.from(afterResult.first));

      final changes = calculateChanges(
        transactionType: TransactionType.update,
        before: before,
        after: after,
      );

      transactionLogRepository.log(
        entityType: EntityType.slate,
        entityId: id!,
        transactionType: TransactionType.update,
        summary: generateSummary(
          transactionType: TransactionType.update,
          entityType: EntityType.slate,
          entityTitle: after['title'] as String,
          changes: changes,
        ),
        changes: changes,
      );
    });

    return showSlate(args);
  }

  /// List slates with optional filters.
  CallToolResult listSlates(Map<String, dynamic>? args) {
    final status = args?['status'] as String?;

    final conditions = <String>[];
    final values = <Object?>[];

    if (status != null && status.isNotEmpty) {
      if (requireOneOf(status, 'status', validSlateStatuses)
          case final error?) {
        return error;
      }
      conditions.add('r.status = ?');
      values.add(status);
    }

    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(" AND ")}';

    final query = '''
      SELECT 
        r.id,
        r.title,
        r.notes,
        r.status,
        r.slate_date,
        r.created_at,
        r.updated_at,
        (SELECT COUNT(*) FROM slate_items ri WHERE ri.slate_id = r.id) as item_count
      FROM slates r
      $whereClause
      ORDER BY r.updated_at DESC
    ''';

    final result = database.select(query, values);

    final slates = result
        .map((row) => {
              'id': row['id'],
              'title': row['title'],
              'notes': row['notes'],
              'status': row['status'],
              'slate_date': row['slate_date'],
              'item_count': row['item_count'],
              'created_at': row['created_at'],
              'updated_at': row['updated_at'],
            })
        .toList();

    return jsonResult({
      'slates': slates,
      'count': slates.length,
      'filters': {
        'status': ?status,
      },
    });
  }

  /// Add an item to a slate.
  CallToolResult addItemToSlate(Map<String, dynamic>? args) {
    final slateId = args?['release_id'] as String?;
    final itemId = args?['item_id'] as String?;

    if (requireString(slateId, 'release_id') case final error?) {
      return error;
    }

    if (requireString(itemId, 'item_id') case final error?) {
      return error;
    }

    // Verify both exist
    final slateResult =
        database.select('SELECT id, title FROM slates WHERE id = ?', [slateId]);
    if (slateResult.isEmpty) {
      return notFoundError('Slate', slateId!);
    }

    final itemResult =
        database.select('SELECT id, title FROM items WHERE id = ?', [itemId]);
    if (itemResult.isEmpty) {
      return notFoundError('Item', itemId!);
    }

    final now = DateTime.now().toUtc().toIso8601String();

    withRetryTransactionSync(database, () {
      database.execute('''
        INSERT OR IGNORE INTO slate_items (slate_id, item_id, added_at)
        VALUES (?, ?, ?)
      ''', [slateId, itemId, now]);

      transactionLogRepository.log(
        entityType: EntityType.slate,
        entityId: slateId!,
        transactionType: TransactionType.update,
        summary:
            "Item '${itemResult.first['title']}' added to slate '${slateResult.first['title']}'",
        changes: {
          'before': null,
          'after': {
            'action': 'add_item',
            'item_id': itemId,
            'slate_id': slateId,
          },
        },
      );
    });

    return jsonResult({
      'success': true,
      'message': 'Item added to slate',
      'slate_id': slateId,
      'item_id': itemId,
    });
  }

  /// Remove an item from a slate.
  CallToolResult removeItemFromSlate(Map<String, dynamic>? args) {
    final slateId = args?['release_id'] as String?;
    final itemId = args?['item_id'] as String?;

    if (requireString(slateId, 'release_id') case final error?) {
      return error;
    }

    if (requireString(itemId, 'item_id') case final error?) {
      return error;
    }

    withRetryTransactionSync(database, () {
      database.execute(
          'DELETE FROM slate_items WHERE slate_id = ? AND item_id = ?',
          [slateId, itemId]);

      transactionLogRepository.log(
        entityType: EntityType.slate,
        entityId: slateId!,
        transactionType: TransactionType.update,
        summary: "Item removed from slate",
        changes: {
          'before': {
            'action': 'remove_item',
            'item_id': itemId,
            'slate_id': slateId,
          },
          'after': null,
        },
      );
    });

    return jsonResult({
      'success': true,
      'message': 'Item removed from slate',
      'slate_id': slateId,
      'item_id': itemId,
    });
  }

  /// Add an item to a task (link backlog item to task).
  CallToolResult addItemToTask(Map<String, dynamic>? args) {
    final taskId = args?['task_id'] as String?;
    final itemId = args?['item_id'] as String?;

    if (requireString(taskId, 'task_id') case final error?) {
      return error;
    }

    if (requireString(itemId, 'item_id') case final error?) {
      return error;
    }

    // Verify both exist
    final taskResult =
        database.select('SELECT id FROM tasks WHERE id = ?', [taskId]);
    if (taskResult.isEmpty) {
      return notFoundError('Task', taskId!);
    }

    final itemResult =
        database.select('SELECT id FROM items WHERE id = ?', [itemId]);
    if (itemResult.isEmpty) {
      return notFoundError('Item', itemId!);
    }

    final now = DateTime.now().toUtc().toIso8601String();

    withRetryTransactionSync(database, () {
      database.execute('''
        INSERT OR IGNORE INTO task_items (task_id, item_id, added_at)
        VALUES (?, ?, ?)
      ''', [taskId, itemId, now]);
    });

    return jsonResult({
      'success': true,
      'message': 'Item linked to task',
      'task_id': taskId,
      'item_id': itemId,
    });
  }

  /// Remove an item from a task (unlink backlog item from task).
  CallToolResult removeItemFromTask(Map<String, dynamic>? args) {
    final taskId = args?['task_id'] as String?;
    final itemId = args?['item_id'] as String?;

    if (requireString(taskId, 'task_id') case final error?) {
      return error;
    }

    if (requireString(itemId, 'item_id') case final error?) {
      return error;
    }

    withRetryTransactionSync(database, () {
      database.execute(
          'DELETE FROM task_items WHERE task_id = ? AND item_id = ?',
          [taskId, itemId]);
    });

    return jsonResult({
      'success': true,
      'message': 'Item unlinked from task',
      'task_id': taskId,
      'item_id': itemId,
    });
  }
}
