import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:planner_mcp/planner_mcp.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Tests for backlog item and release operations.
void main() {
  late Directory tempDir;
  late Database db;
  late TransactionLogRepository transactionLogRepo;
  late ItemOperations itemOps;
  late ReleaseOperations releaseOps;

  final uuid = Uuid();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('planner_backlog_test_');
    final dbPath = p.join(tempDir.path, 'test.db');
    db = initializeDatabase(dbPath);
    transactionLogRepo = TransactionLogRepository(db);
    transactionLogRepo.initializeTable();
    itemOps = ItemOperations(
      database: db,
      transactionLogRepository: transactionLogRepo,
    );
    releaseOps = ReleaseOperations(
      database: db,
      transactionLogRepository: transactionLogRepo,
    );
  });

  tearDown(() async {
    db.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Helper to parse JSON from CallToolResult.
  Map<String, dynamic> parseResult(CallToolResult result) {
    final text = (result.content.first as TextContent).text;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// Helper to get text from CallToolResult.
  String resultText(CallToolResult result) {
    return (result.content.first as TextContent).text;
  }

  /// Helper to create a task and return its ID.
  String createTask(String title, {String projectId = 'test-project'}) {
    final id = uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    db.execute('''
      INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
    ''', [id, projectId, title, 'todo', now, now]);
    return id;
  }

  // ===== ITEM OPERATIONS =====

  group('Item Operations', () {
    group('add-item', () {
      test('creates item with all fields', () {
        final result = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Fix login bug',
          'details': 'Users cannot log in with SSO',
          'type': 'bug',
          'status': 'open',
        });

        final data = parseResult(result);
        expect(data['success'], isTrue);
        expect(data['message'], 'Item created');
        expect(data['item']['title'], 'Fix login bug');
        expect(data['item']['details'], 'Users cannot log in with SSO');
        expect(data['item']['type'], 'bug');
        expect(data['item']['status'], 'open');
        expect(data['item']['project_id'], 'test-project');
        expect(data['item']['id'], isNotEmpty);
        expect(data['item']['created_at'], isNotEmpty);
        expect(data['item']['updated_at'], isNotEmpty);
      });

      test('uses default type and status when not provided', () {
        final result = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'New feature',
        });

        final data = parseResult(result);
        expect(data['item']['type'], 'feature');
        expect(data['item']['status'], 'open');
      });

      test('validates required title', () {
        final result = itemOps.addItem({
          'project_id': 'test-project',
        });

        final text = resultText(result);
        expect(text, contains('title is required'));
      });

      test('defaults project_id to empty string when not provided', () {
        final result = itemOps.addItem({
          'title': 'Some item',
        });

        final data = parseResult(result);
        expect(data['success'], isTrue);
        expect(data['item']['project_id'], '');
      });

      test('validates type enum', () {
        final result = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Item',
          'type': 'invalid_type',
        });

        final text = resultText(result);
        expect(text, contains('type'));
      });

      test('validates status enum', () {
        final result = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Item',
          'status': 'invalid_status',
        });

        final text = resultText(result);
        expect(text, contains('status'));
      });

      test('creates transaction log entry', () {
        final result = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Logged item',
        });

        final data = parseResult(result);
        final itemId = data['item']['id'] as String;

        final logs = db.select(
          'SELECT * FROM transaction_logs WHERE entity_id = ? AND entity_type = ?',
          [itemId, 'item'],
        );
        expect(logs, hasLength(1));
        expect(logs.first['transaction_type'], 'create');
        expect(logs.first['summary'], contains('Logged item'));
      });
    });

    group('show-item', () {
      test('returns item with empty history for new item', () {
        final addResult = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Show me',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        final result = itemOps.showItem({'id': itemId});
        final data = parseResult(result);

        expect(data['id'], itemId);
        expect(data['title'], 'Show me');
        expect(data['history'], isEmpty);
      });

      test('returns 404 for non-existent item', () {
        final result = itemOps.showItem({'id': 'non-existent'});
        final text = resultText(result);
        expect(text, contains('not found'));
      });
    });

    group('update-item', () {
      test('updates title and records history', () {
        final addResult = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Original title',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        final updateResult = itemOps.updateItem({
          'id': itemId,
          'title': 'Updated title',
        });
        final updateData = parseResult(updateResult);

        expect(updateData['title'], 'Updated title');

        // Check history
        final history = updateData['history'] as List;
        expect(history, hasLength(1));
        expect(history[0]['field_name'], 'title');
        expect(history[0]['old_value'], 'Original title');
        expect(history[0]['new_value'], 'Updated title');
      });

      test('updates status and records history', () {
        final addResult = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Close me',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        itemOps.updateItem({
          'id': itemId,
          'status': 'closed',
        });

        final showResult = itemOps.showItem({'id': itemId});
        final showData = parseResult(showResult);

        expect(showData['status'], 'closed');
        final history = showData['history'] as List;
        expect(history, hasLength(1));
        expect(history[0]['field_name'], 'status');
        expect(history[0]['old_value'], 'open');
        expect(history[0]['new_value'], 'closed');
      });

      test('updates multiple fields and records separate history entries', () {
        final addResult = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Multi update',
          'type': 'feature',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        itemOps.updateItem({
          'id': itemId,
          'title': 'New title',
          'type': 'bug',
        });

        final showResult = itemOps.showItem({'id': itemId});
        final showData = parseResult(showResult);

        final history = showData['history'] as List;
        expect(history, hasLength(2));
        final fieldNames = history.map((h) => h['field_name']).toSet();
        expect(fieldNames, containsAll(['title', 'type']));
      });

      test('validates type enum on update', () {
        final addResult = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Item',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        final result = itemOps.updateItem({
          'id': itemId,
          'type': 'invalid',
        });
        final text = resultText(result);
        expect(text, contains('type'));
      });

      test('returns error for non-existent item', () {
        final result = itemOps.updateItem({
          'id': 'non-existent',
          'title': 'New',
        });
        final text = resultText(result);
        expect(text, contains('not found'));
      });

      test('returns error when no fields to update', () {
        final addResult = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Item',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        final result = itemOps.updateItem({'id': itemId});
        final text = resultText(result);
        expect(text, contains('No fields to update'));
      });

      test('creates transaction log entry on update', () {
        final addResult = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Log update',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        itemOps.updateItem({
          'id': itemId,
          'status': 'closed',
        });

        final logs = db.select(
          'SELECT * FROM transaction_logs WHERE entity_id = ? AND entity_type = ? AND transaction_type = ?',
          [itemId, 'item', 'update'],
        );
        expect(logs, hasLength(1));
        expect(logs.first['summary'], contains('status changed'));
      });
    });

    group('list-items', () {
      test('returns items ordered by updated_at DESC', () {
        itemOps.addItem({
          'project_id': 'test-project',
          'title': 'First item',
        });
        itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Second item',
        });

        final result = itemOps.listItems({});
        final data = parseResult(result);

        expect(data['count'], 2);
        final items = data['items'] as List;
        expect(items[0]['title'], 'Second item');
        expect(items[1]['title'], 'First item');
      });

      test('returns all items regardless of project_id filter (deprecated)', () {
        itemOps.addItem({
          'project_id': 'project-a',
          'title': 'Item A',
        });
        itemOps.addItem({
          'project_id': 'project-b',
          'title': 'Item B',
        });

        // project_id filter is deprecated — all items should be returned
        final result = itemOps.listItems({'project_id': 'project-a'});
        final data = parseResult(result);

        expect(data['count'], 2);
      });

      test('filters by type', () {
        itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Bug fix',
          'type': 'bug',
        });
        itemOps.addItem({
          'project_id': 'test-project',
          'title': 'New feature',
          'type': 'feature',
        });

        final result = itemOps.listItems({'type': 'bug'});
        final data = parseResult(result);

        expect(data['count'], 1);
        expect((data['items'] as List)[0]['title'], 'Bug fix');
      });

      test('filters by status', () {
        final addResult = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Open item',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Another open',
        });

        itemOps.updateItem({'id': itemId, 'status': 'closed'});

        final result = itemOps.listItems({'status': 'closed'});
        final data = parseResult(result);

        expect(data['count'], 1);
        expect((data['items'] as List)[0]['title'], 'Open item');
      });

      test('search_query matches on title and details', () {
        itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Login bug',
          'details': 'Some details',
        });
        itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Other item',
          'details': 'Login related issue',
        });
        itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Unrelated',
          'details': 'Nothing here',
        });

        final result = itemOps.listItems({'search_query': 'Login'});
        final data = parseResult(result);

        expect(data['count'], 2);
      });

      test('includes release count per item', () {
        // Create item
        final addResult = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Item with releases',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        // Create two releases and link item to both
        final rel1Result = releaseOps.addRelease({
          'project_id': 'test-project',
          'title': 'Release 1',
        });
        final rel1Id = parseResult(rel1Result)['release']['id'] as String;

        final rel2Result = releaseOps.addRelease({
          'project_id': 'test-project',
          'title': 'Release 2',
        });
        final rel2Id = parseResult(rel2Result)['release']['id'] as String;

        releaseOps.addItemToRelease({'release_id': rel1Id, 'item_id': itemId});
        releaseOps.addItemToRelease({'release_id': rel2Id, 'item_id': itemId});

        final result = itemOps.listItems({});
        final data = parseResult(result);
        final items = data['items'] as List;
        final targetItem = items.firstWhere((i) => i['id'] == itemId);
        expect(targetItem['release_count'], 2);
      });
    });
  });

  // ===== RELEASE OPERATIONS =====

  group('Release Operations', () {
    group('add-release', () {
      test('creates release with all fields', () {
        final result = releaseOps.addRelease({
          'project_id': 'test-project',
          'title': 'v1.0',
          'notes': 'First release with new features',
        });

        final data = parseResult(result);
        expect(data['success'], isTrue);
        expect(data['release']['title'], 'v1.0');
        expect(data['release']['notes'], 'First release with new features');
        expect(data['release']['project_id'], 'test-project');
        expect(data['release']['id'], isNotEmpty);
      });

      test('validates required fields and defaults project_id', () {
        // project_id is no longer required — should default to empty string
        final result1 = releaseOps.addRelease({'title': 'v1.0'});
        final data1 = parseResult(result1);
        expect(data1['success'], isTrue);
        expect(data1['release']['project_id'], '');

        // title is still required
        final result2 = releaseOps.addRelease({});
        expect(resultText(result2), contains('title is required'));
      });

      test('creates transaction log entry', () {
        final result = releaseOps.addRelease({
          'project_id': 'test-project',
          'title': 'Logged release',
        });

        final data = parseResult(result);
        final releaseId = data['release']['id'] as String;

        final logs = db.select(
          'SELECT * FROM transaction_logs WHERE entity_id = ? AND entity_type = ?',
          [releaseId, 'release'],
        );
        expect(logs, hasLength(1));
        expect(logs.first['transaction_type'], 'create');
      });
    });

    group('show-release', () {
      test('returns release with empty items list for new release', () {
        final addResult = releaseOps.addRelease({
          'project_id': 'test-project',
          'title': 'v2.0',
        });
        final addData = parseResult(addResult);
        final releaseId = addData['release']['id'] as String;

        final result = releaseOps.showRelease({'id': releaseId});
        final data = parseResult(result);

        expect(data['id'], releaseId);
        expect(data['title'], 'v2.0');
        expect(data['items'], isEmpty);
      });

      test('returns 404 for non-existent release', () {
        final result = releaseOps.showRelease({'id': 'non-existent'});
        expect(resultText(result), contains('not found'));
      });
    });

    group('update-release', () {
      test('updates title and notes', () {
        final addResult = releaseOps.addRelease({
          'project_id': 'test-project',
          'title': 'Old title',
          'notes': 'Old notes',
        });
        final addData = parseResult(addResult);
        final releaseId = addData['release']['id'] as String;

        final updateResult = releaseOps.updateRelease({
          'id': releaseId,
          'title': 'New title',
          'notes': 'New notes',
        });
        final updateData = parseResult(updateResult);

        expect(updateData['title'], 'New title');
        expect(updateData['notes'], 'New notes');
      });

      test('returns error for non-existent release', () {
        final result = releaseOps.updateRelease({
          'id': 'non-existent',
          'title': 'New',
        });
        expect(resultText(result), contains('not found'));
      });

      test('returns error when no fields to update', () {
        final addResult = releaseOps.addRelease({
          'project_id': 'test-project',
          'title': 'Release',
        });
        final addData = parseResult(addResult);
        final releaseId = addData['release']['id'] as String;

        final result = releaseOps.updateRelease({'id': releaseId});
        expect(resultText(result), contains('No fields to update'));
      });
    });

    group('list-releases', () {
      test('returns releases ordered by updated_at DESC', () {
        releaseOps.addRelease({
          'project_id': 'test-project',
          'title': 'v1.0',
        });
        releaseOps.addRelease({
          'project_id': 'test-project',
          'title': 'v2.0',
        });

        final result = releaseOps.listReleases({});
        final data = parseResult(result);

        expect(data['count'], 2);
        final releases = data['releases'] as List;
        expect(releases[0]['title'], 'v2.0');
      });

      test('returns all releases regardless of project_id filter (deprecated)', () {
        releaseOps.addRelease({
          'project_id': 'project-a',
          'title': 'Release A',
        });
        releaseOps.addRelease({
          'project_id': 'project-b',
          'title': 'Release B',
        });

        // project_id filter is deprecated — all releases should be returned
        final result = releaseOps.listReleases({'project_id': 'project-a'});
        final data = parseResult(result);

        expect(data['count'], 2);
      });

      test('includes item count per release', () {
        final relResult = releaseOps.addRelease({
          'project_id': 'test-project',
          'title': 'Release with items',
        });
        final releaseId = parseResult(relResult)['release']['id'] as String;

        final item1Result = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Item 1',
        });
        final item1Id = parseResult(item1Result)['item']['id'] as String;

        final item2Result = itemOps.addItem({
          'project_id': 'test-project',
          'title': 'Item 2',
        });
        final item2Id = parseResult(item2Result)['item']['id'] as String;

        releaseOps.addItemToRelease({'release_id': releaseId, 'item_id': item1Id});
        releaseOps.addItemToRelease({'release_id': releaseId, 'item_id': item2Id});

        final result = releaseOps.listReleases({});
        final data = parseResult(result);
        final releases = data['releases'] as List;
        final targetRelease = releases.firstWhere((r) => r['id'] == releaseId);
        expect(targetRelease['item_count'], 2);
      });
    });
  });

  // ===== RELEASE-ITEM JUNCTION =====

  group('Release-Item Junction', () {
    test('add-item-to-release links item to release', () {
      final relResult = releaseOps.addRelease({
        'project_id': 'test-project',
        'title': 'v1.0',
      });
      final releaseId = parseResult(relResult)['release']['id'] as String;

      final itemResult = itemOps.addItem({
        'project_id': 'test-project',
        'title': 'Feature X',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      final result = releaseOps.addItemToRelease({
        'release_id': releaseId,
        'item_id': itemId,
      });
      final data = parseResult(result);
      expect(data['success'], isTrue);

      // Verify via show-release
      final showResult = releaseOps.showRelease({'id': releaseId});
      final showData = parseResult(showResult);
      final items = showData['items'] as List;
      expect(items, hasLength(1));
      expect(items[0]['id'], itemId);
      expect(items[0]['title'], 'Feature X');
    });

    test('add-item-to-release ignores duplicate', () {
      final relResult = releaseOps.addRelease({
        'project_id': 'test-project',
        'title': 'v1.0',
      });
      final releaseId = parseResult(relResult)['release']['id'] as String;

      final itemResult = itemOps.addItem({
        'project_id': 'test-project',
        'title': 'Feature X',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      releaseOps.addItemToRelease({'release_id': releaseId, 'item_id': itemId});
      releaseOps.addItemToRelease({'release_id': releaseId, 'item_id': itemId});

      // Should still have only one link
      final rows = db.select(
        'SELECT COUNT(*) as cnt FROM release_items WHERE release_id = ? AND item_id = ?',
        [releaseId, itemId],
      );
      expect(rows.first['cnt'], 1);
    });

    test('add-item-to-release validates release exists', () {
      final itemResult = itemOps.addItem({
        'project_id': 'test-project',
        'title': 'Feature X',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      final result = releaseOps.addItemToRelease({
        'release_id': 'non-existent',
        'item_id': itemId,
      });
      expect(resultText(result), contains('not found'));
    });

    test('add-item-to-release validates item exists', () {
      final relResult = releaseOps.addRelease({
        'project_id': 'test-project',
        'title': 'v1.0',
      });
      final releaseId = parseResult(relResult)['release']['id'] as String;

      final result = releaseOps.addItemToRelease({
        'release_id': releaseId,
        'item_id': 'non-existent',
      });
      expect(resultText(result), contains('not found'));
    });

    test('remove-item-from-release unlinks item', () {
      final relResult = releaseOps.addRelease({
        'project_id': 'test-project',
        'title': 'v1.0',
      });
      final releaseId = parseResult(relResult)['release']['id'] as String;

      final itemResult = itemOps.addItem({
        'project_id': 'test-project',
        'title': 'Feature X',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      releaseOps.addItemToRelease({'release_id': releaseId, 'item_id': itemId});
      releaseOps.removeItemFromRelease({'release_id': releaseId, 'item_id': itemId});

      final showResult = releaseOps.showRelease({'id': releaseId});
      final showData = parseResult(showResult);
      expect(showData['items'], isEmpty);
    });
  });

  // ===== TASK-ITEM JUNCTION =====

  group('Task-Item Junction', () {
    test('add-item-to-task links item to task', () {
      final taskId = createTask('My task');
      final itemResult = itemOps.addItem({
        'project_id': 'test-project',
        'title': 'Linked item',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      final result = releaseOps.addItemToTask({
        'task_id': taskId,
        'item_id': itemId,
      });
      final data = parseResult(result);
      expect(data['success'], isTrue);

      // Verify in DB
      final rows = db.select(
        'SELECT * FROM task_items WHERE task_id = ? AND item_id = ?',
        [taskId, itemId],
      );
      expect(rows, hasLength(1));
    });

    test('add-item-to-task ignores duplicate', () {
      final taskId = createTask('My task');
      final itemResult = itemOps.addItem({
        'project_id': 'test-project',
        'title': 'Linked item',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      releaseOps.addItemToTask({'task_id': taskId, 'item_id': itemId});
      releaseOps.addItemToTask({'task_id': taskId, 'item_id': itemId});

      final rows = db.select(
        'SELECT COUNT(*) as cnt FROM task_items WHERE task_id = ? AND item_id = ?',
        [taskId, itemId],
      );
      expect(rows.first['cnt'], 1);
    });

    test('add-item-to-task validates task exists', () {
      final itemResult = itemOps.addItem({
        'project_id': 'test-project',
        'title': 'Item',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      final result = releaseOps.addItemToTask({
        'task_id': 'non-existent',
        'item_id': itemId,
      });
      expect(resultText(result), contains('not found'));
    });

    test('add-item-to-task validates item exists', () {
      final taskId = createTask('My task');

      final result = releaseOps.addItemToTask({
        'task_id': taskId,
        'item_id': 'non-existent',
      });
      expect(resultText(result), contains('not found'));
    });

    test('remove-item-from-task unlinks item', () {
      final taskId = createTask('My task');
      final itemResult = itemOps.addItem({
        'project_id': 'test-project',
        'title': 'Linked item',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      releaseOps.addItemToTask({'task_id': taskId, 'item_id': itemId});
      releaseOps.removeItemFromTask({'task_id': taskId, 'item_id': itemId});

      final rows = db.select(
        'SELECT COUNT(*) as cnt FROM task_items WHERE task_id = ? AND item_id = ?',
        [taskId, itemId],
      );
      expect(rows.first['cnt'], 0);
    });
  });

  // ===== MIGRATION =====

  group('Migration', () {
    test('fresh database creates all backlog tables', () {
      // The setUp already creates a fresh database, just verify tables exist
      final tables = db.select(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      );
      final tableNames = tables.map((r) => r['name'] as String).toSet();

      expect(tableNames, contains('items'));
      expect(tableNames, contains('item_history'));
      expect(tableNames, contains('releases'));
      expect(tableNames, contains('release_items'));
      expect(tableNames, contains('task_items'));
    });

    test('schema version is set to 5', () {
      final result = db.select(
        "SELECT value FROM schema_metadata WHERE key = 'schema_version'",
      );
      expect(result.first['value'], '5');
    });

    test('releases table has status and release_date columns', () {
      // Create a release and verify the columns exist
      final result = releaseOps.addRelease({
        'title': 'Migration test',
        'status': 'todo',
        'release_date': '2026-04-01T00:00:00Z',
      });
      final data = parseResult(result);
      expect(data['success'], isTrue);
      expect(data['release']['status'], 'todo');
      expect(data['release']['release_date'], '2026-04-01T00:00:00Z');
    });
  });

  // ===== RELEASE STATUS TESTS =====

  group('Release Status', () {
    test('creates release with specific status', () {
      final result = releaseOps.addRelease({
        'title': 'Started release',
        'status': 'started',
      });
      final data = parseResult(result);
      expect(data['success'], isTrue);
      expect(data['release']['status'], 'started');
    });

    test('defaults status to draft when not provided', () {
      final result = releaseOps.addRelease({
        'title': 'Default status',
      });
      final data = parseResult(result);
      expect(data['release']['status'], 'draft');
    });

    test('validates release status on create', () {
      final result = releaseOps.addRelease({
        'title': 'Invalid',
        'status': 'invalid_status',
      });
      final text = resultText(result);
      expect(text, contains('status'));
    });

    test('updates release status', () {
      final addResult = releaseOps.addRelease({
        'title': 'Update me',
      });
      final releaseId = parseResult(addResult)['release']['id'] as String;

      final updateResult = releaseOps.updateRelease({
        'id': releaseId,
        'status': 'released',
      });
      final data = parseResult(updateResult);
      expect(data['status'], 'released');
    });

    test('validates release status on update', () {
      final addResult = releaseOps.addRelease({
        'title': 'Update me',
      });
      final releaseId = parseResult(addResult)['release']['id'] as String;

      final result = releaseOps.updateRelease({
        'id': releaseId,
        'status': 'invalid',
      });
      final text = resultText(result);
      expect(text, contains('status'));
    });

    test('show-release includes status and release_date', () {
      final addResult = releaseOps.addRelease({
        'title': 'Show test',
        'status': 'todo',
        'release_date': '2026-06-15T00:00:00Z',
      });
      final releaseId = parseResult(addResult)['release']['id'] as String;

      final result = releaseOps.showRelease({'id': releaseId});
      final data = parseResult(result);
      expect(data['status'], 'todo');
      expect(data['release_date'], '2026-06-15T00:00:00Z');
    });

    test('list-releases filters by status', () {
      releaseOps.addRelease({'title': 'Draft 1', 'status': 'draft'});
      releaseOps.addRelease({'title': 'Started 1', 'status': 'started'});
      releaseOps.addRelease({'title': 'Draft 2', 'status': 'draft'});

      final result = releaseOps.listReleases({'status': 'draft'});
      final data = parseResult(result);
      expect(data['count'], 2);
      final titles = (data['releases'] as List).map((r) => r['title']).toSet();
      expect(titles, containsAll(['Draft 1', 'Draft 2']));
    });

    test('list-releases includes status and release_date', () {
      releaseOps.addRelease({
        'title': 'v3.0',
        'status': 'todo',
        'release_date': '2026-07-01T00:00:00Z',
      });

      final result = releaseOps.listReleases({});
      final data = parseResult(result);
      final releases = data['releases'] as List;
      expect(releases[0]['status'], 'todo');
      expect(releases[0]['release_date'], '2026-07-01T00:00:00Z');
    });

    test('all valid release statuses are accepted', () {
      for (final status in ['draft', 'todo', 'started', 'done', 'released']) {
        final result = releaseOps.addRelease({
          'title': 'Status $status',
          'status': status,
        });
        final data = parseResult(result);
        expect(data['success'], isTrue, reason: 'Status $status should be valid');
        expect(data['release']['status'], status);
      }
    });
  });

  // ===== RELEASE DATE TESTS =====

  group('Release Date', () {
    test('creates release with release_date', () {
      final result = releaseOps.addRelease({
        'title': 'Dated release',
        'release_date': '2026-12-25T00:00:00Z',
      });
      final data = parseResult(result);
      expect(data['release']['release_date'], '2026-12-25T00:00:00Z');
    });

    test('release_date defaults to null when not provided', () {
      final result = releaseOps.addRelease({
        'title': 'No date',
      });
      final data = parseResult(result);
      expect(data['release']['release_date'], isNull);
    });

    test('updates release_date', () {
      final addResult = releaseOps.addRelease({
        'title': 'Update date',
      });
      final releaseId = parseResult(addResult)['release']['id'] as String;

      final updateResult = releaseOps.updateRelease({
        'id': releaseId,
        'release_date': '2026-09-01T00:00:00Z',
      });
      final data = parseResult(updateResult);
      expect(data['release_date'], '2026-09-01T00:00:00Z');
    });
  });

  // ===== BACKLOG FILTER TESTS =====

  group('Backlog Filter (backlog_only)', () {
    test('returns only items not in any release when backlog_only=true', () {
      // Create 3 items
      final item1Id = parseResult(itemOps.addItem({
        'title': 'Backlog item 1',
      }))['item']['id'] as String;
      final item2Id = parseResult(itemOps.addItem({
        'title': 'Released item',
      }))['item']['id'] as String;
      parseResult(itemOps.addItem({
        'title': 'Backlog item 2',
      }));

      // Assign item2 to a release
      final releaseId = parseResult(releaseOps.addRelease({
        'title': 'v1.0',
      }))['release']['id'] as String;
      releaseOps.addItemToRelease({'release_id': releaseId, 'item_id': item2Id});

      // backlog_only should return only unassigned items
      final result = itemOps.listItems({'backlog_only': true});
      final data = parseResult(result);
      expect(data['count'], 2);
      final ids = (data['items'] as List).map((i) => i['id']).toSet();
      expect(ids, contains(item1Id));
      expect(ids, isNot(contains(item2Id)));
    });

    test('returns all items when backlog_only=false', () {
      final item1Id = parseResult(itemOps.addItem({
        'title': 'Item A',
      }))['item']['id'] as String;
      parseResult(itemOps.addItem({
        'title': 'Item B',
      }));

      // Assign item1 to a release
      final releaseId = parseResult(releaseOps.addRelease({
        'title': 'v1.0',
      }))['release']['id'] as String;
      releaseOps.addItemToRelease({'release_id': releaseId, 'item_id': item1Id});

      final result = itemOps.listItems({'backlog_only': false});
      final data = parseResult(result);
      expect(data['count'], 2);
    });

    test('returns all items when backlog_only is omitted', () {
      parseResult(itemOps.addItem({'title': 'Item A'}));
      final item2Id = parseResult(itemOps.addItem({
        'title': 'Item B',
      }))['item']['id'] as String;

      final releaseId = parseResult(releaseOps.addRelease({
        'title': 'v1.0',
      }))['release']['id'] as String;
      releaseOps.addItemToRelease({'release_id': releaseId, 'item_id': item2Id});

      final result = itemOps.listItems({});
      final data = parseResult(result);
      expect(data['count'], 2);
    });

    test('combines backlog_only with type filter', () {
      final bugId = parseResult(itemOps.addItem({
        'title': 'Backlog bug',
        'type': 'bug',
      }))['item']['id'] as String;
      parseResult(itemOps.addItem({
        'title': 'Backlog feature',
        'type': 'feature',
      }));
      final releasedBugId = parseResult(itemOps.addItem({
        'title': 'Released bug',
        'type': 'bug',
      }))['item']['id'] as String;

      final releaseId = parseResult(releaseOps.addRelease({
        'title': 'v1.0',
      }))['release']['id'] as String;
      releaseOps.addItemToRelease({'release_id': releaseId, 'item_id': releasedBugId});

      // backlog_only + type=bug should only return the backlog bug
      final result = itemOps.listItems({'backlog_only': true, 'type': 'bug'});
      final data = parseResult(result);
      expect(data['count'], 1);
      expect((data['items'] as List)[0]['id'], bugId);
    });

    test('combines backlog_only with status filter', () {
      final openId = parseResult(itemOps.addItem({
        'title': 'Open backlog',
        'status': 'open',
      }))['item']['id'] as String;
      final closedResult = itemOps.addItem({
        'title': 'Closed backlog',
      });
      final closedId = parseResult(closedResult)['item']['id'] as String;
      itemOps.updateItem({'id': closedId, 'status': 'closed'});

      final result = itemOps.listItems({'backlog_only': true, 'status': 'open'});
      final data = parseResult(result);
      expect(data['count'], 1);
      expect((data['items'] as List)[0]['id'], openId);
    });
  });
}