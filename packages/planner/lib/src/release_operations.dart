import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'planner.dart';

/// Valid release statuses.
const validReleaseStatuses = ['draft', 'todo', 'started', 'done', 'released'];

final _uuid = Uuid();

/// Release operations handler for backlog releases.
class ReleaseOperations {
  final Database database;
  final TransactionLogRepository transactionLogRepository;

  ReleaseOperations({
    required this.database,
    required this.transactionLogRepository,
  });

  /// Add a new release.
  CallToolResult addRelease(Map<String, dynamic>? args) {
    final projectId = args?['project_id'] as String? ?? '';
    final title = args?['title'] as String?;
    final notes = args?['notes'] as String?;
    final status = args?['status'] as String? ?? 'draft';
    final releaseDate = args?['release_date'] as String?;

    if (requireString(title, 'title') case final error?) {
      return error;
    }

    if (requireOneOf(status, 'status', validReleaseStatuses)
        case final error?) {
      return error;
    }

    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();

    final releaseData = {
      'id': id,
      'project_id': projectId,
      'title': title,
      'notes': notes,
      'status': status,
      'release_date': releaseDate,
      'created_at': now,
      'updated_at': now,
    };

    withRetryTransactionSync(database, () {
      database.execute('''
        INSERT INTO releases (id, project_id, title, notes, status, release_date, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''', [id, projectId, title, notes, status, releaseDate, now, now]);

      transactionLogRepository.log(
        entityType: EntityType.release,
        entityId: id,
        transactionType: TransactionType.create,
        summary: generateSummary(
          transactionType: TransactionType.create,
          entityType: EntityType.release,
          entityTitle: title!,
          projectId: projectId,
        ),
        changes: calculateChanges(
          transactionType: TransactionType.create,
          after: releaseData,
        ),
        projectId: projectId,
      );
    });

    return jsonResult({
      'success': true,
      'message': 'Release created',
      'release': releaseData,
    });
  }

  /// Show release details with assigned items.
  CallToolResult showRelease(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    final releaseResult =
        database.select('SELECT * FROM releases WHERE id = ?', [id]);

    if (releaseResult.isEmpty) {
      return notFoundError('Release', id!);
    }

    final release = releaseResult.first;

    // Get items assigned to this release via release_items junction
    final itemsResult = database.select('''
      SELECT i.id, i.title, i.type, i.status, ri.added_at
      FROM items i
      INNER JOIN release_items ri ON ri.item_id = i.id
      WHERE ri.release_id = ?
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
      'id': release['id'],
      'project_id': release['project_id'],
      'title': release['title'],
      'notes': release['notes'],
      'status': release['status'],
      'release_date': release['release_date'],
      'created_at': release['created_at'],
      'updated_at': release['updated_at'],
      'items': items,
    });
  }

  /// Update release properties.
  CallToolResult updateRelease(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    final existingResult =
        database.select('SELECT * FROM releases WHERE id = ?', [id]);
    if (existingResult.isEmpty) {
      return notFoundError('Release', id!);
    }

    final before =
        releaseToLoggable(Map<String, dynamic>.from(existingResult.first));

    final updates = <String>[];
    final values = <Object?>[];

    if (args?.containsKey('title') == true) {
      updates.add('title = ?');
      values.add(args!['title']);
    }

    if (args?.containsKey('notes') == true) {
      updates.add('notes = ?');
      values.add(args!['notes']);
    }

    if (args?.containsKey('status') == true) {
      final newStatus = args!['status'] as String;
      if (requireOneOf(newStatus, 'status', validReleaseStatuses)
          case final error?) {
        return error;
      }
      updates.add('status = ?');
      values.add(newStatus);
    }

    if (args?.containsKey('release_date') == true) {
      updates.add('release_date = ?');
      values.add(args!['release_date']);
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
          'UPDATE releases SET ${updates.join(", ")} WHERE id = ?', values);

      final afterResult =
          database.select('SELECT * FROM releases WHERE id = ?', [id]);
      final after =
          releaseToLoggable(Map<String, dynamic>.from(afterResult.first));

      final changes = calculateChanges(
        transactionType: TransactionType.update,
        before: before,
        after: after,
      );

      transactionLogRepository.log(
        entityType: EntityType.release,
        entityId: id!,
        transactionType: TransactionType.update,
        summary: generateSummary(
          transactionType: TransactionType.update,
          entityType: EntityType.release,
          entityTitle: after['title'] as String,
          projectId: after['project_id'] as String?,
          changes: changes,
        ),
        changes: changes,
        projectId: after['project_id'] as String?,
      );
    });

    return showRelease(args);
  }

  /// List releases with optional filters.
  CallToolResult listReleases(Map<String, dynamic>? args) {
    final projectId = args?['project_id'] as String?;
    final status = args?['status'] as String?;

    final conditions = <String>[];
    final values = <Object?>[];

    if (status != null && status.isNotEmpty) {
      if (requireOneOf(status, 'status', validReleaseStatuses)
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
        r.project_id,
        r.title,
        r.notes,
        r.status,
        r.release_date,
        r.created_at,
        r.updated_at,
        (SELECT COUNT(*) FROM release_items ri WHERE ri.release_id = r.id) as item_count
      FROM releases r
      $whereClause
      ORDER BY r.updated_at DESC
    ''';

    final result = database.select(query, values);

    final releases = result
        .map((row) => {
              'id': row['id'],
              'project_id': row['project_id'],
              'title': row['title'],
              'notes': row['notes'],
              'status': row['status'],
              'release_date': row['release_date'],
              'item_count': row['item_count'],
              'created_at': row['created_at'],
              'updated_at': row['updated_at'],
            })
        .toList();

    return jsonResult({
      'releases': releases,
      'count': releases.length,
      'filters': {
        'project_id': ?projectId,
        'status': ?status,
      },
    });
  }

  /// Add an item to a release.
  CallToolResult addItemToRelease(Map<String, dynamic>? args) {
    final releaseId = args?['release_id'] as String?;
    final itemId = args?['item_id'] as String?;

    if (requireString(releaseId, 'release_id') case final error?) {
      return error;
    }

    if (requireString(itemId, 'item_id') case final error?) {
      return error;
    }

    // Verify both exist
    final releaseResult =
        database.select('SELECT id, title FROM releases WHERE id = ?', [releaseId]);
    if (releaseResult.isEmpty) {
      return notFoundError('Release', releaseId!);
    }

    final itemResult =
        database.select('SELECT id, title FROM items WHERE id = ?', [itemId]);
    if (itemResult.isEmpty) {
      return notFoundError('Item', itemId!);
    }

    final now = DateTime.now().toUtc().toIso8601String();

    withRetryTransactionSync(database, () {
      database.execute('''
        INSERT OR IGNORE INTO release_items (release_id, item_id, added_at)
        VALUES (?, ?, ?)
      ''', [releaseId, itemId, now]);

      transactionLogRepository.log(
        entityType: EntityType.release,
        entityId: releaseId!,
        transactionType: TransactionType.update,
        summary:
            "Item '${itemResult.first['title']}' added to release '${releaseResult.first['title']}'",
        changes: {
          'before': null,
          'after': {
            'action': 'add_item',
            'item_id': itemId,
            'release_id': releaseId,
          },
        },
      );
    });

    return jsonResult({
      'success': true,
      'message': 'Item added to release',
      'release_id': releaseId,
      'item_id': itemId,
    });
  }

  /// Remove an item from a release.
  CallToolResult removeItemFromRelease(Map<String, dynamic>? args) {
    final releaseId = args?['release_id'] as String?;
    final itemId = args?['item_id'] as String?;

    if (requireString(releaseId, 'release_id') case final error?) {
      return error;
    }

    if (requireString(itemId, 'item_id') case final error?) {
      return error;
    }

    withRetryTransactionSync(database, () {
      database.execute(
          'DELETE FROM release_items WHERE release_id = ? AND item_id = ?',
          [releaseId, itemId]);

      transactionLogRepository.log(
        entityType: EntityType.release,
        entityId: releaseId!,
        transactionType: TransactionType.update,
        summary: "Item removed from release",
        changes: {
          'before': {
            'action': 'remove_item',
            'item_id': itemId,
            'release_id': releaseId,
          },
          'after': null,
        },
      );
    });

    return jsonResult({
      'success': true,
      'message': 'Item removed from release',
      'release_id': releaseId,
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
