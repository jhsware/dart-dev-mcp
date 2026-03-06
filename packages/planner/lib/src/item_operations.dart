import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'planner.dart';

/// Valid item types.
const validItemTypes = ['feature', 'improvement', 'bug', 'change'];

/// Valid item statuses.
const validItemStatuses = ['open', 'closed'];

final _uuid = Uuid();

/// Item operations handler for backlog items.
class ItemOperations {
  final Database database;
  final TransactionLogRepository transactionLogRepository;

  ItemOperations({
    required this.database,
    required this.transactionLogRepository,
  });

  /// Add a new backlog item.
  CallToolResult addItem(Map<String, dynamic>? args) {
    final projectId = args?['project_id'] as String?;
    final title = args?['title'] as String?;
    final details = args?['details'] as String?;
    final type = args?['type'] as String? ?? 'feature';
    final status = args?['status'] as String? ?? 'open';

    if (requireString(projectId, 'project_id') case final error?) {
      return error;
    }

    if (requireString(title, 'title') case final error?) {
      return error;
    }

    if (requireOneOf(type, 'type', validItemTypes) case final error?) {
      return error;
    }

    if (requireOneOf(status, 'status', validItemStatuses) case final error?) {
      return error;
    }

    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();

    final itemData = {
      'id': id,
      'project_id': projectId,
      'title': title,
      'details': details,
      'type': type,
      'status': status,
      'created_at': now,
      'updated_at': now,
    };

    withRetryTransactionSync(database, () {
      database.execute('''
        INSERT INTO items (id, project_id, title, details, type, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''', [id, projectId, title, details, type, status, now, now]);

      transactionLogRepository.log(
        entityType: EntityType.item,
        entityId: id,
        transactionType: TransactionType.create,
        summary: generateSummary(
          transactionType: TransactionType.create,
          entityType: EntityType.item,
          entityTitle: title!,
          projectId: projectId,
        ),
        changes: calculateChanges(
          transactionType: TransactionType.create,
          after: itemData,
        ),
        projectId: projectId,
      );
    });

    return jsonResult({
      'success': true,
      'message': 'Item created',
      'item': itemData,
    });
  }

  /// Show item details with history.
  CallToolResult showItem(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    final itemResult =
        database.select('SELECT * FROM items WHERE id = ?', [id]);

    if (itemResult.isEmpty) {
      return notFoundError('Item', id!);
    }

    final item = itemResult.first;

    // Get item history ordered by changed_at DESC
    final historyResult = database.select(
        'SELECT id, field_name, old_value, new_value, changed_at FROM item_history WHERE item_id = ? ORDER BY changed_at DESC',
        [id]);

    final history = historyResult
        .map((row) => {
              'id': row['id'],
              'field_name': row['field_name'],
              'old_value': row['old_value'],
              'new_value': row['new_value'],
              'changed_at': row['changed_at'],
            })
        .toList();

    return jsonResult({
      'id': item['id'],
      'project_id': item['project_id'],
      'title': item['title'],
      'details': item['details'],
      'type': item['type'],
      'status': item['status'],
      'created_at': item['created_at'],
      'updated_at': item['updated_at'],
      'history': history,
    });
  }

  /// Update item properties with history tracking.
  CallToolResult updateItem(Map<String, dynamic>? args) {
    final id = args?['id'] as String?;

    if (requireString(id, 'id') case final error?) {
      return error;
    }

    // Get item before update for diff calculation
    final existingResult =
        database.select('SELECT * FROM items WHERE id = ?', [id]);
    if (existingResult.isEmpty) {
      return notFoundError('Item', id!);
    }

    final existing = Map<String, dynamic>.from(existingResult.first);
    final before = itemToLoggable(existing);

    final updates = <String>[];
    final values = <Object?>[];
    final changedFields = <MapEntry<String, MapEntry<String?, String?>>>[];

    if (args?.containsKey('title') == true) {
      final newTitle = args!['title'] as String?;
      if (existing['title'] != newTitle) {
        changedFields.add(MapEntry(
            'title',
            MapEntry(existing['title'] as String?, newTitle)));
      }
      updates.add('title = ?');
      values.add(newTitle);
    }

    if (args?.containsKey('details') == true) {
      final newDetails = args!['details'] as String?;
      if (existing['details'] != newDetails) {
        changedFields.add(MapEntry(
            'details',
            MapEntry(existing['details'] as String?, newDetails)));
      }
      updates.add('details = ?');
      values.add(newDetails);
    }

    if (args?.containsKey('type') == true) {
      final newType = args!['type'] as String;
      if (requireOneOf(newType, 'type', validItemTypes) case final error?) {
        return error;
      }
      if (existing['type'] != newType) {
        changedFields.add(MapEntry(
            'type',
            MapEntry(existing['type'] as String?, newType)));
      }
      updates.add('type = ?');
      values.add(newType);
    }

    if (args?.containsKey('status') == true) {
      final newStatus = args!['status'] as String;
      if (requireOneOf(newStatus, 'status', validItemStatuses)
          case final error?) {
        return error;
      }
      if (existing['status'] != newStatus) {
        changedFields.add(MapEntry(
            'status',
            MapEntry(existing['status'] as String?, newStatus)));
      }
      updates.add('status = ?');
      values.add(newStatus);
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
          'UPDATE items SET ${updates.join(", ")} WHERE id = ?', values);

      // Insert item_history rows for each changed field
      for (final change in changedFields) {
        final historyId = _uuid.v4();
        database.execute('''
          INSERT INTO item_history (id, item_id, field_name, old_value, new_value, changed_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [historyId, id, change.key, change.value.key, change.value.value, now]);
      }

      // Get item after update
      final afterResult =
          database.select('SELECT * FROM items WHERE id = ?', [id]);
      final after =
          itemToLoggable(Map<String, dynamic>.from(afterResult.first));

      final changes = calculateChanges(
        transactionType: TransactionType.update,
        before: before,
        after: after,
      );

      transactionLogRepository.log(
        entityType: EntityType.item,
        entityId: id!,
        transactionType: TransactionType.update,
        summary: generateSummary(
          transactionType: TransactionType.update,
          entityType: EntityType.item,
          entityTitle: after['title'] as String,
          projectId: after['project_id'] as String?,
          changes: changes,
        ),
        changes: changes,
        projectId: after['project_id'] as String?,
      );
    });

    return showItem(args);
  }

  /// List items with optional filters.
  CallToolResult listItems(Map<String, dynamic>? args) {
    final projectId = args?['project_id'] as String?;
    final searchQuery = args?['search_query'] as String?;
    final type = args?['type'] as String?;
    final status = args?['status'] as String?;

    // Validate type if provided
    if (type != null && type.isNotEmpty) {
      if (requireOneOf(type, 'type', validItemTypes) case final error?) {
        return error;
      }
    }

    // Validate status if provided
    if (status != null && status.isNotEmpty) {
      if (requireOneOf(status, 'status', validItemStatuses)
          case final error?) {
        return error;
      }
    }

    final conditions = <String>[];
    final values = <Object?>[];

    if (projectId != null && projectId.isNotEmpty) {
      conditions.add('i.project_id = ?');
      values.add(projectId);
    }

    if (searchQuery != null && searchQuery.isNotEmpty) {
      conditions.add('(i.title LIKE ? OR i.details LIKE ?)');
      values.add('%$searchQuery%');
      values.add('%$searchQuery%');
    }

    if (type != null && type.isNotEmpty) {
      conditions.add('i.type = ?');
      values.add(type);
    }

    if (status != null && status.isNotEmpty) {
      conditions.add('i.status = ?');
      values.add(status);
    }

    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(" AND ")}';

    final query = '''
      SELECT 
        i.id,
        i.project_id,
        i.title,
        i.type,
        i.status,
        i.created_at,
        i.updated_at,
        (SELECT COUNT(*) FROM release_items ri WHERE ri.item_id = i.id) as release_count
      FROM items i
      $whereClause
      ORDER BY i.updated_at DESC
    ''';

    final result = database.select(query, values);

    final items = result
        .map((row) => {
              'id': row['id'],
              'project_id': row['project_id'],
              'title': row['title'],
              'type': row['type'],
              'status': row['status'],
              'release_count': row['release_count'],
              'created_at': row['created_at'],
              'updated_at': row['updated_at'],
            })
        .toList();

    return jsonResult({
      'items': items,
      'count': items.length,
      'filters': {
        'project_id': ?projectId,
        'search_query': ?searchQuery,
        'type': ?type,
        'status': ?status,
      },
    });
  }
}
