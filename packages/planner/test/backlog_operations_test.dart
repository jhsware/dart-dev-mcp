import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:planner_mcp/planner_mcp.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Tests for backlog item and slate operations.
void main() {
  late Directory tempDir;
  late Database db;
  late TransactionLogRepository transactionLogRepo;
  late ItemOperations itemOps;
  late SlateOperations slateOps;
  late TaskOperations taskOps;

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
    slateOps = SlateOperations(
      database: db,
      transactionLogRepository: transactionLogRepo,
    );
    taskOps = TaskOperations(
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
        expect(data['item']['id'], isNotEmpty);
        expect(data['item']['created_at'], isNotEmpty);
        expect(data['item']['updated_at'], isNotEmpty);
      });

      test('uses default type and status when not provided', () {
        final result = itemOps.addItem({
          'title': 'New feature',
        });

        final data = parseResult(result);
        expect(data['item']['type'], 'feature');
        expect(data['item']['status'], 'open');
      });

      test('validates required title', () {
        final result = itemOps.addItem({
        });

        final text = resultText(result);
        expect(text, contains('title is required'));
      });


      test('validates type enum', () {
        final result = itemOps.addItem({
          'title': 'Item',
          'type': 'invalid_type',
        });

        final text = resultText(result);
        expect(text, contains('type'));
      });

      test('validates status enum', () {
        final result = itemOps.addItem({
          'title': 'Item',
          'status': 'invalid_status',
        });

        final text = resultText(result);
        expect(text, contains('status'));
      });

      test('creates transaction log entry', () {
        final result = itemOps.addItem({
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
          'title': 'First item',
        });
        itemOps.addItem({
          'title': 'Second item',
        });

        final result = itemOps.listItems({});
        final data = parseResult(result);

        expect(data['count'], 2);
        final items = data['items'] as List;
        expect(items[0]['title'], 'Second item');
        expect(items[1]['title'], 'First item');
      });


      test('filters by type', () {
        itemOps.addItem({
          'title': 'Bug fix',
          'type': 'bug',
        });
        itemOps.addItem({
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
          'title': 'Open item',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        itemOps.addItem({
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
          'title': 'Login bug',
          'details': 'Some details',
        });
        itemOps.addItem({
          'title': 'Other item',
          'details': 'Login related issue',
        });
        itemOps.addItem({
          'title': 'Unrelated',
          'details': 'Nothing here',
        });

        final result = itemOps.listItems({'search_query': 'Login'});
        final data = parseResult(result);

        expect(data['count'], 2);
      });

      test('includes slate count per item', () {
        // Create item
        final addResult = itemOps.addItem({
          'title': 'Item with slates',
        });
        final addData = parseResult(addResult);
        final itemId = addData['item']['id'] as String;

        // Create two slates and link item to both
        final rel1Result = slateOps.addSlate({
          'title': 'Release 1',
        });
        final rel1Id = parseResult(rel1Result)['slate']['id'] as String;

        final rel2Result = slateOps.addSlate({
          'title': 'Release 2',
        });
        final rel2Id = parseResult(rel2Result)['slate']['id'] as String;

        slateOps.addItemToSlate({'release_id': rel1Id, 'item_id': itemId});
        slateOps.addItemToSlate({'release_id': rel2Id, 'item_id': itemId});

        final result = itemOps.listItems({});
        final data = parseResult(result);
        final items = data['items'] as List;
        final targetItem = items.firstWhere((i) => i['id'] == itemId);
        expect(targetItem['slate_count'], 2);
      });
    });
  });

  // ===== RELEASE OPERATIONS =====

  group('Slate Operations', () {
    group('add-slate', () {
      test('creates slate with all fields', () {
        final result = slateOps.addSlate({
          'title': 'v1.0',
          'notes': 'First slate with new features',
        });

        final data = parseResult(result);
        expect(data['success'], isTrue);
        expect(data['slate']['title'], 'v1.0');
        expect(data['slate']['notes'], 'First slate with new features');
        expect(data['slate']['id'], isNotEmpty);
      });

      test('validates required fields', () {
        final result1 = slateOps.addSlate({'title': 'v1.0'});
        final data1 = parseResult(result1);
        expect(data1['success'], isTrue);

        // title is still required
        final result2 = slateOps.addSlate({});
        expect(resultText(result2), contains('title is required'));
      });

      test('creates transaction log entry', () {
        final result = slateOps.addSlate({
          'title': 'Logged slate',
        });

        final data = parseResult(result);
        final slateId = data['slate']['id'] as String;

        final logs = db.select(
          'SELECT * FROM transaction_logs WHERE entity_id = ? AND entity_type = ?',
          [slateId, 'slate'],
        );
        expect(logs, hasLength(1));
        expect(logs.first['transaction_type'], 'create');
      });
    });

    group('show-slate', () {
      test('returns slate with empty items list for new slate', () {
        final addResult = slateOps.addSlate({
          'title': 'v2.0',
        });
        final addData = parseResult(addResult);
        final slateId = addData['slate']['id'] as String;

        final result = slateOps.showSlate({'id': slateId});
        final data = parseResult(result);

        expect(data['id'], slateId);
        expect(data['title'], 'v2.0');
        expect(data['items'], isEmpty);
      });

      test('returns 404 for non-existent slate', () {
        final result = slateOps.showSlate({'id': 'non-existent'});
        expect(resultText(result), contains('not found'));
      });
    });

    group('update-slate', () {
      test('updates title and notes', () {
        final addResult = slateOps.addSlate({
          'title': 'Old title',
          'notes': 'Old notes',
        });
        final addData = parseResult(addResult);
        final slateId = addData['slate']['id'] as String;

        final updateResult = slateOps.updateSlate({
          'id': slateId,
          'title': 'New title',
          'notes': 'New notes',
        });
        final updateData = parseResult(updateResult);

        expect(updateData['title'], 'New title');
        expect(updateData['notes'], 'New notes');
      });

      test('returns error for non-existent slate', () {
        final result = slateOps.updateSlate({
          'id': 'non-existent',
          'title': 'New',
        });
        expect(resultText(result), contains('not found'));
      });

      test('returns error when no fields to update', () {
        final addResult = slateOps.addSlate({
          'title': 'Release',
        });
        final addData = parseResult(addResult);
        final slateId = addData['slate']['id'] as String;

        final result = slateOps.updateSlate({'id': slateId});
        expect(resultText(result), contains('No fields to update'));
      });
    });

    group('list-slates', () {
      test('returns slates ordered by updated_at DESC', () {
        slateOps.addSlate({
          'title': 'v1.0',
        });
        slateOps.addSlate({
          'title': 'v2.0',
        });

        final result = slateOps.listSlates({});
        final data = parseResult(result);

        expect(data['count'], 2);
        final slates = data['slates'] as List;
        expect(slates[0]['title'], 'v2.0');
      });


      test('includes item count per slate', () {
        final relResult = slateOps.addSlate({
          'title': 'Slate with items',
        });
        final slateId = parseResult(relResult)['slate']['id'] as String;

        final item1Result = itemOps.addItem({
          'title': 'Item 1',
        });
        final item1Id = parseResult(item1Result)['item']['id'] as String;

        final item2Result = itemOps.addItem({
          'title': 'Item 2',
        });
        final item2Id = parseResult(item2Result)['item']['id'] as String;

        slateOps.addItemToSlate({'release_id': slateId, 'item_id': item1Id});
        slateOps.addItemToSlate({'release_id': slateId, 'item_id': item2Id});

        final result = slateOps.listSlates({});
        final data = parseResult(result);
        final slates = data['slates'] as List;
        final targetSlate = slates.firstWhere((r) => r['id'] == slateId);
        expect(targetSlate['item_count'], 2);
      });
    });
  });

  // ===== RELEASE-ITEM JUNCTION =====

  group('Slate-Item Junction', () {
    test('add-item-to-slate links item to slate', () {
      final relResult = slateOps.addSlate({
        'title': 'v1.0',
      });
      final slateId = parseResult(relResult)['slate']['id'] as String;

      final itemResult = itemOps.addItem({
        'title': 'Feature X',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      final result = slateOps.addItemToSlate({
        'release_id': slateId,
        'item_id': itemId,
      });
      final data = parseResult(result);
      expect(data['success'], isTrue);

      // Verify via show-slate
      final showResult = slateOps.showSlate({'id': slateId});
      final showData = parseResult(showResult);
      final items = showData['items'] as List;
      expect(items, hasLength(1));
      expect(items[0]['id'], itemId);
      expect(items[0]['title'], 'Feature X');
    });

    test('add-item-to-slate ignores duplicate', () {
      final relResult = slateOps.addSlate({
        'title': 'v1.0',
      });
      final slateId = parseResult(relResult)['slate']['id'] as String;

      final itemResult = itemOps.addItem({
        'title': 'Feature X',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      slateOps.addItemToSlate({'release_id': slateId, 'item_id': itemId});
      slateOps.addItemToSlate({'release_id': slateId, 'item_id': itemId});

      // Should still have only one link
      final rows = db.select(
        'SELECT COUNT(*) as cnt FROM slate_items WHERE slate_id = ? AND item_id = ?',
        [slateId, itemId],
      );
      expect(rows.first['cnt'], 1);
    });

    test('add-item-to-slate validates slate exists', () {
      final itemResult = itemOps.addItem({
        'title': 'Feature X',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      final result = slateOps.addItemToSlate({
        'release_id': 'non-existent',
        'item_id': itemId,
      });
      expect(resultText(result), contains('not found'));
    });

    test('add-item-to-slate validates item exists', () {
      final relResult = slateOps.addSlate({
        'title': 'v1.0',
      });
      final slateId = parseResult(relResult)['slate']['id'] as String;

      final result = slateOps.addItemToSlate({
        'release_id': slateId,
        'item_id': 'non-existent',
      });
      expect(resultText(result), contains('not found'));
    });

    test('remove-item-from-slate unlinks item', () {
      final relResult = slateOps.addSlate({
        'title': 'v1.0',
      });
      final slateId = parseResult(relResult)['slate']['id'] as String;

      final itemResult = itemOps.addItem({
        'title': 'Feature X',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      slateOps.addItemToSlate({'release_id': slateId, 'item_id': itemId});
      slateOps.removeItemFromSlate({'release_id': slateId, 'item_id': itemId});

      final showResult = slateOps.showSlate({'id': slateId});
      final showData = parseResult(showResult);
      expect(showData['items'], isEmpty);
    });
  });

  // ===== TASK-ITEM JUNCTION =====

  group('Task-Item Junction', () {
    test('add-item-to-task links item to task', () {
      final taskId = createTask('My task');
      final itemResult = itemOps.addItem({
        'title': 'Linked item',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      final result = slateOps.addItemToTask({
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
        'title': 'Linked item',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      slateOps.addItemToTask({'task_id': taskId, 'item_id': itemId});
      slateOps.addItemToTask({'task_id': taskId, 'item_id': itemId});

      final rows = db.select(
        'SELECT COUNT(*) as cnt FROM task_items WHERE task_id = ? AND item_id = ?',
        [taskId, itemId],
      );
      expect(rows.first['cnt'], 1);
    });

    test('add-item-to-task validates task exists', () {
      final itemResult = itemOps.addItem({
        'title': 'Item',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      final result = slateOps.addItemToTask({
        'task_id': 'non-existent',
        'item_id': itemId,
      });
      expect(resultText(result), contains('not found'));
    });

    test('add-item-to-task validates item exists', () {
      final taskId = createTask('My task');

      final result = slateOps.addItemToTask({
        'task_id': taskId,
        'item_id': 'non-existent',
      });
      expect(resultText(result), contains('not found'));
    });

    test('remove-item-from-task unlinks item', () {
      final taskId = createTask('My task');
      final itemResult = itemOps.addItem({
        'title': 'Linked item',
      });
      final itemId = parseResult(itemResult)['item']['id'] as String;

      slateOps.addItemToTask({'task_id': taskId, 'item_id': itemId});
      slateOps.removeItemFromTask({'task_id': taskId, 'item_id': itemId});

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
      expect(tableNames, contains('slates'));
      expect(tableNames, contains('slate_items'));
      expect(tableNames, contains('task_items'));
    });

    test('schema version is set to 6', () {
      final result = db.select(
        "SELECT value FROM schema_metadata WHERE key = 'schema_version'",
      );
      expect(result.first['value'], '6');
    });

    test('slates table has status and slate_date columns', () {
      // Create a slate and verify the columns exist
      final result = slateOps.addSlate({
        'title': 'Migration test',
        'status': 'todo',
        'release_date': '2026-04-01T00:00:00Z',
      });
      final data = parseResult(result);
      expect(data['success'], isTrue);
      expect(data['slate']['status'], 'todo');
      expect(data['slate']['slate_date'], '2026-04-01T00:00:00Z');
    });
  });

  // ===== RELEASE STATUS TESTS =====

  group('Slate Status', () {
    test('creates slate with specific status', () {
      final result = slateOps.addSlate({
        'title': 'Started slate',
        'status': 'started',
      });
      final data = parseResult(result);
      expect(data['success'], isTrue);
      expect(data['slate']['status'], 'started');
    });

    test('defaults status to draft when not provided', () {
      final result = slateOps.addSlate({
        'title': 'Default status',
      });
      final data = parseResult(result);
      expect(data['slate']['status'], 'draft');
    });

    test('validates slate status on create', () {
      final result = slateOps.addSlate({
        'title': 'Invalid',
        'status': 'invalid_status',
      });
      final text = resultText(result);
      expect(text, contains('status'));
    });

    test('updates slate status', () {
      final addResult = slateOps.addSlate({
        'title': 'Update me',
      });
      final slateId = parseResult(addResult)['slate']['id'] as String;

      final updateResult = slateOps.updateSlate({
        'id': slateId,
        'status': 'released',
      });
      final data = parseResult(updateResult);
      expect(data['status'], 'released');
    });

    test('validates slate status on update', () {
      final addResult = slateOps.addSlate({
        'title': 'Update me',
      });
      final slateId = parseResult(addResult)['slate']['id'] as String;

      final result = slateOps.updateSlate({
        'id': slateId,
        'status': 'invalid',
      });
      final text = resultText(result);
      expect(text, contains('status'));
    });

    test('show-slate includes status and slate_date', () {
      final addResult = slateOps.addSlate({
        'title': 'Show test',
        'status': 'todo',
        'release_date': '2026-06-15T00:00:00Z',
      });
      final slateId = parseResult(addResult)['slate']['id'] as String;

      final result = slateOps.showSlate({'id': slateId});
      final data = parseResult(result);
      expect(data['status'], 'todo');
      expect(data['slate_date'], '2026-06-15T00:00:00Z');
    });

    test('list-slates filters by status', () {
      slateOps.addSlate({'title': 'Draft 1', 'status': 'draft'});
      slateOps.addSlate({'title': 'Started 1', 'status': 'started'});
      slateOps.addSlate({'title': 'Draft 2', 'status': 'draft'});

      final result = slateOps.listSlates({'status': 'draft'});
      final data = parseResult(result);
      expect(data['count'], 2);
      final titles = (data['slates'] as List).map((r) => r['title']).toSet();
      expect(titles, containsAll(['Draft 1', 'Draft 2']));
    });

    test('list-slates includes status and slate_date', () {
      slateOps.addSlate({
        'title': 'v3.0',
        'status': 'todo',
        'release_date': '2026-07-01T00:00:00Z',
      });

      final result = slateOps.listSlates({});
      final data = parseResult(result);
      final slates = data['slates'] as List;
      expect(slates[0]['status'], 'todo');
      expect(slates[0]['slate_date'], '2026-07-01T00:00:00Z');
    });

    test('all valid slate statuses are accepted', () {
      for (final status in ['draft', 'todo', 'started', 'done', 'released']) {
        final result = slateOps.addSlate({
          'title': 'Status $status',
          'status': status,
        });
        final data = parseResult(result);
        expect(data['success'], isTrue, reason: 'Status $status should be valid');
        expect(data['slate']['status'], status);
      }
    });
  });

  // ===== RELEASE DATE TESTS =====

  group('Slate Date', () {
    test('creates slate with slate_date', () {
      final result = slateOps.addSlate({
        'title': 'Dated slate',
        'release_date': '2026-12-25T00:00:00Z',
      });
      final data = parseResult(result);
      expect(data['slate']['slate_date'], '2026-12-25T00:00:00Z');
    });

    test('slate_date defaults to null when not provided', () {
      final result = slateOps.addSlate({
        'title': 'No date',
      });
      final data = parseResult(result);
      expect(data['slate']['slate_date'], isNull);
    });

    test('updates slate_date', () {
      final addResult = slateOps.addSlate({
        'title': 'Update date',
      });
      final slateId = parseResult(addResult)['slate']['id'] as String;

      final updateResult = slateOps.updateSlate({
        'id': slateId,
        'release_date': '2026-09-01T00:00:00Z',
      });
      final data = parseResult(updateResult);
      expect(data['slate_date'], '2026-09-01T00:00:00Z');
    });
  });

  // ===== BACKLOG FILTER TESTS =====

  group('Backlog Filter (backlog_only)', () {
    test('returns only items not in any slate when backlog_only=true', () {
      // Create 3 items
      final item1Id = parseResult(itemOps.addItem({
        'title': 'Backlog item 1',
      }))['item']['id'] as String;
      final item2Id = parseResult(itemOps.addItem({
        'title': 'Slated item',
      }))['item']['id'] as String;
      parseResult(itemOps.addItem({
        'title': 'Backlog item 2',
      }));

      // Assign item2 to a slate
      final slateId = parseResult(slateOps.addSlate({
        'title': 'v1.0',
      }))['slate']['id'] as String;
      slateOps.addItemToSlate({'release_id': slateId, 'item_id': item2Id});

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

      // Assign item1 to a slate
      final slateId = parseResult(slateOps.addSlate({
        'title': 'v1.0',
      }))['slate']['id'] as String;
      slateOps.addItemToSlate({'release_id': slateId, 'item_id': item1Id});

      final result = itemOps.listItems({'backlog_only': false});
      final data = parseResult(result);
      expect(data['count'], 2);
    });

    test('returns all items when backlog_only is omitted', () {
      parseResult(itemOps.addItem({'title': 'Item A'}));
      final item2Id = parseResult(itemOps.addItem({
        'title': 'Item B',
      }))['item']['id'] as String;

      final slateId = parseResult(slateOps.addSlate({
        'title': 'v1.0',
      }))['slate']['id'] as String;
      slateOps.addItemToSlate({'release_id': slateId, 'item_id': item2Id});

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
      final slatedBugId = parseResult(itemOps.addItem({
        'title': 'Slated bug',
        'type': 'bug',
      }))['item']['id'] as String;

      final slateId = parseResult(slateOps.addSlate({
        'title': 'v1.0',
      }))['slate']['id'] as String;
      slateOps.addItemToSlate({'release_id': slateId, 'item_id': slatedBugId});

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

  // ===== CROSS-ENTITY VISIBILITY TESTS =====

  group('Cross-Entity Visibility', () {
    group('show-task linked items', () {
      test('includes linked backlog items in show-task response', () {
        // Create a task via taskOps
        final taskResult = taskOps.addTask({
          'title': 'Task with items',
        });
        final taskId = parseResult(taskResult)['task']['id'] as String;

        // Create items
        final item1Id = parseResult(itemOps.addItem({
          'title': 'Bug fix',
          'type': 'bug',
          'status': 'open',
        }))['item']['id'] as String;
        final item2Id = parseResult(itemOps.addItem({
          'title': 'New feature',
          'type': 'feature',
          'status': 'closed',
        }))['item']['id'] as String;

        // Link items to task
        slateOps.addItemToTask({'task_id': taskId, 'item_id': item1Id});
        slateOps.addItemToTask({'task_id': taskId, 'item_id': item2Id});

        // Show task and verify linked_items
        final showResult = taskOps.showTask({'id': taskId});
        final data = parseResult(showResult);

        expect(data['linked_items'], isA<List>());
        final linkedItems = data['linked_items'] as List;
        expect(linkedItems, hasLength(2));

        // Verify item fields are present
        final itemIds = linkedItems.map((i) => i['id']).toSet();
        expect(itemIds, contains(item1Id));
        expect(itemIds, contains(item2Id));

        // Verify each item has required fields
        for (final item in linkedItems) {
          expect(item, containsPair('id', isNotNull));
          expect(item, containsPair('title', isNotNull));
          expect(item, containsPair('type', isNotNull));
          expect(item, containsPair('status', isNotNull));
        }
      });

      test('returns empty linked_items when task has no linked items', () {
        final taskResult = taskOps.addTask({
          'title': 'Task without items',
        });
        final taskId = parseResult(taskResult)['task']['id'] as String;

        final showResult = taskOps.showTask({'id': taskId});
        final data = parseResult(showResult);

        expect(data['linked_items'], isA<List>());
        expect(data['linked_items'], isEmpty);
      });
    });

    group('show-item linked tasks', () {
      test('includes linked tasks in show-item response', () {
        // Create an item
        final itemId = parseResult(itemOps.addItem({
          'title': 'Shared item',
        }))['item']['id'] as String;

        // Create tasks and link
        final task1Result = taskOps.addTask({'title': 'Task A', 'status': 'started'});
        final task1Id = parseResult(task1Result)['task']['id'] as String;
        final task2Result = taskOps.addTask({'title': 'Task B', 'status': 'done'});
        final task2Id = parseResult(task2Result)['task']['id'] as String;

        slateOps.addItemToTask({'task_id': task1Id, 'item_id': itemId});
        slateOps.addItemToTask({'task_id': task2Id, 'item_id': itemId});

        // Show item and verify linked_tasks
        final showResult = itemOps.showItem({'id': itemId});
        final data = parseResult(showResult);

        expect(data['linked_tasks'], isA<List>());
        final linkedTasks = data['linked_tasks'] as List;
        expect(linkedTasks, hasLength(2));

        final taskIds = linkedTasks.map((t) => t['id']).toSet();
        expect(taskIds, contains(task1Id));
        expect(taskIds, contains(task2Id));

        for (final task in linkedTasks) {
          expect(task, containsPair('id', isNotNull));
          expect(task, containsPair('title', isNotNull));
          expect(task, containsPair('status', isNotNull));
        }
      });

      test('returns empty linked_tasks when item has no linked tasks', () {
        final itemId = parseResult(itemOps.addItem({
          'title': 'Standalone item',
        }))['item']['id'] as String;

        final showResult = itemOps.showItem({'id': itemId});
        final data = parseResult(showResult);

        expect(data['linked_tasks'], isA<List>());
        expect(data['linked_tasks'], isEmpty);
      });
    });

    group('show-item linked slates', () {
      test('includes linked slates in show-item response', () {
        // Create an item
        final itemId = parseResult(itemOps.addItem({
          'title': 'Slate item',
        }))['item']['id'] as String;

        // Create slates and link
        final rel1Id = parseResult(slateOps.addSlate({
          'title': 'v1.0',
        }))['slate']['id'] as String;
        final rel2Id = parseResult(slateOps.addSlate({
          'title': 'v2.0',
        }))['slate']['id'] as String;

        slateOps.addItemToSlate({'release_id': rel1Id, 'item_id': itemId});
        slateOps.addItemToSlate({'release_id': rel2Id, 'item_id': itemId});

        // Show item and verify linked_slates
        final showResult = itemOps.showItem({'id': itemId});
        final data = parseResult(showResult);

        expect(data['linked_slates'], isA<List>());
        final linkedSlates = data['linked_slates'] as List;
        expect(linkedSlates, hasLength(2));

        final slateIds = linkedSlates.map((r) => r['id']).toSet();
        expect(slateIds, contains(rel1Id));
        expect(slateIds, contains(rel2Id));

        for (final slate in linkedSlates) {
          expect(slate, containsPair('id', isNotNull));
          expect(slate, containsPair('title', isNotNull));
        }
      });

      test('returns empty linked_slates when item has no linked slates', () {
        final itemId = parseResult(itemOps.addItem({
          'title': 'No slates item',
        }))['item']['id'] as String;

        final showResult = itemOps.showItem({'id': itemId});
        final data = parseResult(showResult);

        expect(data['linked_slates'], isA<List>());
        expect(data['linked_slates'], isEmpty);
      });
    });

    group('combined cross-entity', () {
      test('item linked to both tasks and slates shows all', () {
        // Create an item
        final itemId = parseResult(itemOps.addItem({
          'title': 'Well-connected item',
        }))['item']['id'] as String;

        // Link to a task
        final taskResult = taskOps.addTask({'title': 'Related task'});
        final taskId = parseResult(taskResult)['task']['id'] as String;
        slateOps.addItemToTask({'task_id': taskId, 'item_id': itemId});

        // Link to a slate
        final slateId = parseResult(slateOps.addSlate({
          'title': 'v3.0',
        }))['slate']['id'] as String;
        slateOps.addItemToSlate({'release_id': slateId, 'item_id': itemId});

        // Show item
        final showResult = itemOps.showItem({'id': itemId});
        final data = parseResult(showResult);

        expect(data['linked_tasks'], hasLength(1));
        expect((data['linked_tasks'] as List)[0]['id'], taskId);

        expect(data['linked_slates'], hasLength(1));
        expect((data['linked_slates'] as List)[0]['id'], slateId);
      });
    });
  });

  group('Archived Item Status', () {
    test('creates item with archived status', () {
      final result = itemOps.addItem({
        'title': 'Archived feature',
        'status': 'archived',
      });
      final data = parseResult(result);
      expect(data['item']['status'], 'archived');
    });

    test('updates item status from open to archived', () {
      final createResult = itemOps.addItem({'title': 'Feature to archive'});
      final itemId = parseResult(createResult)['item']['id'] as String;

      final updateResult = itemOps.updateItem({
        'id': itemId,
        'status': 'archived',
      });
      final data = parseResult(updateResult);
      expect(data['status'], 'archived');

      // Verify history records the status change
      final showResult = itemOps.showItem({'id': itemId});
      final showData = parseResult(showResult);
      final history = showData['history'] as List;
      expect(history, isNotEmpty);
      expect(history[0]['field_name'], 'status');
      expect(history[0]['old_value'], 'open');
      expect(history[0]['new_value'], 'archived');
    });

    test('list-items filters by archived status', () {
      // Create items with different statuses
      itemOps.addItem({'title': 'Open item'});

      final archivedResult = itemOps.addItem({'title': 'Archived item'});
      final archivedId = parseResult(archivedResult)['item']['id'] as String;
      itemOps.updateItem({'id': archivedId, 'status': 'archived'});

      final closedResult = itemOps.addItem({'title': 'Closed item'});
      final closedId = parseResult(closedResult)['item']['id'] as String;
      itemOps.updateItem({'id': closedId, 'status': 'closed'});

      // Filter by archived
      final result = itemOps.listItems({'status': 'archived'});
      final data = parseResult(result);
      expect(data['count'], 1);
      expect((data['items'] as List)[0]['title'], 'Archived item');
    });
  });

}