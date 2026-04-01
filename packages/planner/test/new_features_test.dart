import 'dart:convert';
import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:planner_mcp/planner_mcp.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Tests for new planner features:
/// - get-subtask-prompt operation
/// - log-commit and log-merge operations
void main() {
  late Directory tempDir;
  late Database db;
  late TransactionLogRepository transactionLogRepo;
  late StepOperations stepOps;
  late GitLogOperations gitLogOps;

  final uuid = Uuid();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('planner_new_features_test_');
    final dbPath = p.join(tempDir.path, 'test.db');
    db = initializeDatabase(dbPath);
    transactionLogRepo = TransactionLogRepository(db);
    transactionLogRepo.initializeTable();
    stepOps = StepOperations(
      database: db,
      transactionLogRepository: transactionLogRepo,
      promptPackService: PromptPackService(),
    );
    gitLogOps = GitLogOperations(
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

  /// Helper to parse JSON from CallToolResult.
  Map<String, dynamic> parseResult(CallToolResult result) {
    final text = (result.content.first as TextContent).text;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// Helper to get text from CallToolResult.
  String resultText(CallToolResult result) {
    return (result.content.first as TextContent).text;
  }

  group('get-subtask-prompt', () {
    test('returns sub-task details for step with sub_task_id', () {
      // Create parent task
      final parentTaskId = createTask('Parent: My parent task');

      // Create sub-task with steps
      final subTaskId = createTask('Implement feature X');
      final now = DateTime.now().toUtc().toIso8601String();
      db.execute('''
        INSERT INTO steps (id, task_id, title, status, sort_order, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      ''', [uuid.v4(), subTaskId, 'Sub-step 1', 'todo', 1, now, now]);
      db.execute('''
        INSERT INTO steps (id, task_id, title, status, sort_order, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      ''', [uuid.v4(), subTaskId, 'Sub-step 2', 'done', 2, now, now]);

      // Create parent step referencing sub-task
      final parentStepResult = stepOps.addStep({
        'task_id': parentTaskId,
        'title': 'Do feature X',
        'sub_task_id': subTaskId,
      });
      final parentStepData = parseResult(parentStepResult);
      final parentStepId = parentStepData['step']['id'] as String;

      // Call get-subtask-prompt — now returns rendered text, not JSON
      final result = stepOps.getSubtaskPrompt({'id': parentStepId});
      final text = resultText(result);

      expect(text, contains(subTaskId));
      expect(text, contains('Implement feature X'));
      expect(text, contains('Sub-step 1'));
      expect(text, contains('Sub-step 2'));
    });

    test('returns error when step has no sub_task_id', () {
      final taskId = createTask('Regular task');
      final stepResult = stepOps.addStep({
        'task_id': taskId,
        'title': 'Regular step',
      });
      final stepData = parseResult(stepResult);
      final stepId = stepData['step']['id'] as String;

      final result = stepOps.getSubtaskPrompt({'id': stepId});
      final text = resultText(result);

      expect(text, contains('Step has no linked sub-task'));
    });

    test('returns error when step does not exist', () {
      final result = stepOps.getSubtaskPrompt({'id': 'non-existent-step'});
      final text = resultText(result);

      expect(text, contains('not found'));
    });

    test('returns error when sub-task does not exist', () {
      final taskId = createTask('Parent task');
      final stepResult = stepOps.addStep({
        'task_id': taskId,
        'title': 'Step with bad ref',
        'sub_task_id': 'non-existent-task',
      });
      final stepData = parseResult(stepResult);
      final stepId = stepData['step']['id'] as String;

      final result = stepOps.getSubtaskPrompt({'id': stepId});
      final text = resultText(result);

      expect(text, contains('not found'));
    });

    test('includes sub_task_id in sub-task steps', () {
      final parentTaskId = createTask('Parent: Top level');
      final subTaskId = createTask('Sub-task');
      final subSubTaskId = createTask('Sub-sub-task');

      // Sub-task has a step that references a sub-sub-task
      final now = DateTime.now().toUtc().toIso8601String();
      db.execute('''
        INSERT INTO steps (id, task_id, title, status, sub_task_id, sort_order, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''', [uuid.v4(), subTaskId, 'Nested step', 'todo', subSubTaskId, 1, now, now]);

      // Parent step referencing sub-task
      final parentStepResult = stepOps.addStep({
        'task_id': parentTaskId,
        'title': 'Do sub-task',
        'sub_task_id': subTaskId,
      });
      final parentStepData = parseResult(parentStepResult);
      final parentStepId = parentStepData['step']['id'] as String;

      // get-subtask-prompt now returns rendered text, not JSON
      final result = stepOps.getSubtaskPrompt({'id': parentStepId});
      final text = resultText(result);

      expect(text, contains('Nested step'));
      expect(text, contains('sub_task_id: $subSubTaskId'));
    });
  });

  group('log-commit', () {
    test('creates transaction log entry for commit', () {
      final taskId = createTask('My task');

      final result = gitLogOps.logCommit({
        'commit_hash': 'abc1234567890',
        'branch': 'feature/test',
        'task_id': taskId,
      });

      final data = parseResult(result);
      expect(data['success'], isTrue);
      expect(data['log_entry_id'], isNotEmpty);

      // Verify in transaction_logs
      final logs = db.select(
        'SELECT * FROM transaction_logs WHERE id = ?',
        [data['log_entry_id']],
      );
      expect(logs, hasLength(1));
      expect(logs.first['entity_type'], 'task');
      expect(logs.first['entity_id'], taskId);
      expect(logs.first['transaction_type'], 'update');
      expect(logs.first['summary'], contains('abc1234'));
      expect(logs.first['summary'], contains("feature/test"));
    });

    test('includes step_id and message in changes', () {
      final taskId = createTask('My task');

      final result = gitLogOps.logCommit({
        'commit_hash': 'def456',
        'branch': 'main',
        'task_id': taskId,
        'step_id': 'step-123',
        'message': 'Fix the bug',
      });

      final data = parseResult(result);
      final logs = db.select(
        'SELECT changes FROM transaction_logs WHERE id = ?',
        [data['log_entry_id']],
      );
      final changes = jsonDecode(logs.first['changes'] as String) as Map<String, dynamic>;
      expect(changes['after']['step_id'], 'step-123');
      expect(changes['after']['message'], 'Fix the bug');
      expect(changes['after']['type'], 'commit');
    });

    test('returns error for non-existent task', () {
      final result = gitLogOps.logCommit({
        'commit_hash': 'abc123',
        'branch': 'main',
        'task_id': 'non-existent',
      });

      final text = resultText(result);
      expect(text, contains('not found'));
    });

    test('returns error when commit_hash is missing', () {
      final taskId = createTask('My task');
      final result = gitLogOps.logCommit({
        'branch': 'main',
        'task_id': taskId,
      });
      final text = resultText(result);
      expect(text, contains('commit_hash is required'));
    });



  });

  group('log-merge', () {
    test('creates transaction log entry for merge', () {
      final taskId = createTask('My task');

      final result = gitLogOps.logMerge({
        'commit_hash': 'merge123456789',
        'source_branch': 'feature/test',
        'target_branch': 'main',
        'task_id': taskId,
      });

      final data = parseResult(result);
      expect(data['success'], isTrue);
      expect(data['log_entry_id'], isNotEmpty);

      final logs = db.select(
        'SELECT * FROM transaction_logs WHERE id = ?',
        [data['log_entry_id']],
      );
      expect(logs, hasLength(1));
      expect(logs.first['summary'], contains("feature/test"));
      expect(logs.first['summary'], contains('main'));
      expect(logs.first['summary'], contains('merge12'));
    });

    test('includes branch info in changes', () {
      final taskId = createTask('My task');

      final result = gitLogOps.logMerge({
        'commit_hash': 'merge789',
        'source_branch': 'feature/x',
        'target_branch': 'develop',
        'task_id': taskId,
      });

      final data = parseResult(result);
      final logs = db.select(
        'SELECT changes FROM transaction_logs WHERE id = ?',
        [data['log_entry_id']],
      );
      final changes = jsonDecode(logs.first['changes'] as String) as Map<String, dynamic>;
      expect(changes['after']['source_branch'], 'feature/x');
      expect(changes['after']['target_branch'], 'develop');
      expect(changes['after']['type'], 'merge');
    });

    test('returns error for non-existent task', () {
      final result = gitLogOps.logMerge({
        'commit_hash': 'abc123',
        'source_branch': 'feature/test',
        'target_branch': 'main',
        'task_id': 'non-existent',
      });

      final text = resultText(result);
      expect(text, contains('not found'));
    });
    test('returns error when source_branch is missing', () {
      final taskId = createTask('My task');
      final result = gitLogOps.logMerge({
        'commit_hash': 'abc123',
        'target_branch': 'main',
        'task_id': taskId,
      });
      final text = resultText(result);
      expect(text, contains('source_branch is required'));
    });
  });

  group('add-step with sub_task_id', () {
    test('stores sub_task_id in step', () {
      final taskId = createTask('My task');
      final subTaskId = uuid.v4();

      final result = stepOps.addStep({
        'task_id': taskId,
        'title': 'Step with sub-task',
        'sub_task_id': subTaskId,
      });

      final data = parseResult(result);
      expect(data['step']['sub_task_id'], subTaskId);

      // Verify in DB
      final dbResult = db.select(
        'SELECT sub_task_id FROM steps WHERE id = ?',
        [data['step']['id']],
      );
      expect(dbResult.first['sub_task_id'], subTaskId);
    });

    test('sub_task_id is null when not provided', () {
      final taskId = createTask('My task');

      final result = stepOps.addStep({
        'task_id': taskId,
        'title': 'Regular step',
      });

      final data = parseResult(result);
      expect(data['step']['sub_task_id'], isNull);
    });
  });

  group('show-step with sub_task_id', () {
    test('returns sub_task_id in response', () {
      final taskId = createTask('My task');
      final subTaskId = uuid.v4();

      final addResult = stepOps.addStep({
        'task_id': taskId,
        'title': 'Step with ref',
        'sub_task_id': subTaskId,
      });
      final addData = parseResult(addResult);
      final stepId = addData['step']['id'] as String;

      final showResult = stepOps.showStep({'id': stepId});
      final showData = parseResult(showResult);

      expect(showData['sub_task_id'], subTaskId);
    });

    test('returns null sub_task_id when not set', () {
      final taskId = createTask('My task');

      final addResult = stepOps.addStep({
        'task_id': taskId,
        'title': 'Regular step',
      });
      final addData = parseResult(addResult);
      final stepId = addData['step']['id'] as String;

      final showResult = stepOps.showStep({'id': stepId});
      final showData = parseResult(showResult);

      expect(showData['sub_task_id'], isNull);
    });
  });

  group('update-step with sub_task_id', () {
    test('can set sub_task_id via update', () {
      final taskId = createTask('My task');
      final subTaskId = uuid.v4();

      final addResult = stepOps.addStep({
        'task_id': taskId,
        'title': 'Step to update',
      });
      final addData = parseResult(addResult);
      final stepId = addData['step']['id'] as String;

      final updateResult = stepOps.updateStep({
        'id': stepId,
        'sub_task_id': subTaskId,
      });
      final updateData = parseResult(updateResult);

      expect(updateData['sub_task_id'], subTaskId);
    });

    test('can clear sub_task_id via update', () {
      final taskId = createTask('My task');
      final subTaskId = uuid.v4();

      final addResult = stepOps.addStep({
        'task_id': taskId,
        'title': 'Step with ref',
        'sub_task_id': subTaskId,
      });
      final addData = parseResult(addResult);
      final stepId = addData['step']['id'] as String;

      final updateResult = stepOps.updateStep({
        'id': stepId,
        'sub_task_id': null,
      });
      final updateData = parseResult(updateResult);

      expect(updateData['sub_task_id'], isNull);
    });
  });

  group('migration v7 - add missing added_at columns', () {
    test('adds added_at column to task_items when missing', () async {
      // Create a separate database to simulate external tool scenario
      final migrationTempDir = await Directory.systemTemp
          .createTemp('planner_migration_v7_test_');
      final migrationDbPath = p.join(migrationTempDir.path, 'test.db');

      // Step 1: Manually create a database at schema version 6 with
      // task_items and slate_items tables missing the added_at column,
      // simulating what an external tool (e.g. viewer app) would create.
      final rawDb = sqlite3.open(migrationDbPath);
      rawDb.execute('PRAGMA journal_mode=WAL');
      rawDb.execute('PRAGMA foreign_keys=ON');

      // Create schema_metadata and set version to 6
      rawDb.execute('''
        CREATE TABLE schema_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      final now = DateTime.now().toUtc().toIso8601String();
      rawDb.execute('''
        INSERT INTO schema_metadata (key, value, updated_at)
        VALUES ('schema_version', '6', ?)
      ''', [now]);

      // Create required tables (tasks, steps, items, etc.)
      rawDb.execute('''
        CREATE TABLE tasks (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          title TEXT NOT NULL,
          details TEXT,
          status TEXT NOT NULL DEFAULT 'todo',
          memory TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      rawDb.execute('''
        CREATE TABLE steps (
          id TEXT PRIMARY KEY,
          task_id TEXT NOT NULL,
          title TEXT NOT NULL,
          details TEXT,
          status TEXT NOT NULL DEFAULT 'todo',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          sort_order INTEGER,
          sub_task_id TEXT,
          FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
        )
      ''');
      rawDb.execute('''
        CREATE TABLE items (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          title TEXT NOT NULL,
          details TEXT,
          type TEXT NOT NULL DEFAULT 'feature',
          status TEXT NOT NULL DEFAULT 'open',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      rawDb.execute('''
        CREATE TABLE item_history (
          id TEXT PRIMARY KEY,
          item_id TEXT NOT NULL,
          field_name TEXT NOT NULL,
          old_value TEXT,
          new_value TEXT,
          changed_at TEXT NOT NULL,
          FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
        )
      ''');
      rawDb.execute('''
        CREATE TABLE slates (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          title TEXT NOT NULL,
          notes TEXT,
          status TEXT NOT NULL DEFAULT 'draft',
          slate_date TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');

      // Create task_items WITHOUT added_at (simulating external tool)
      rawDb.execute('''
        CREATE TABLE task_items (
          task_id TEXT NOT NULL,
          item_id TEXT NOT NULL,
          PRIMARY KEY (task_id, item_id),
          FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
          FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
        )
      ''');

      // Create slate_items WITHOUT added_at (simulating external tool)
      rawDb.execute('''
        CREATE TABLE slate_items (
          slate_id TEXT NOT NULL,
          item_id TEXT NOT NULL,
          PRIMARY KEY (slate_id, item_id),
          FOREIGN KEY (slate_id) REFERENCES slates(id) ON DELETE CASCADE,
          FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
        )
      ''');

      // Create transaction_logs table (needed by migration v6 check)
      rawDb.execute('''
        CREATE TABLE IF NOT EXISTS transaction_logs (
          id TEXT PRIMARY KEY,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          transaction_type TEXT NOT NULL,
          summary TEXT,
          changes TEXT,
          created_at TEXT NOT NULL
        )
      ''');

      // Insert a task and item, then link them via task_items (no added_at)
      final taskId = uuid.v4();
      final itemId = uuid.v4();
      rawDb.execute('''
        INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
        VALUES (?, 'test-project', 'Test task', 'todo', ?, ?)
      ''', [taskId, now, now]);
      rawDb.execute('''
        INSERT INTO items (id, project_id, title, type, status, created_at, updated_at)
        VALUES (?, 'test-project', 'Test item', 'feature', 'open', ?, ?)
      ''', [itemId, now, now]);
      rawDb.execute('''
        INSERT INTO task_items (task_id, item_id)
        VALUES (?, ?)
      ''', [taskId, itemId]);

      // Verify added_at does NOT exist before migration
      final colsBefore = rawDb.select("PRAGMA table_info(task_items)");
      final colNamesBefore =
          colsBefore.map((row) => row['name'] as String).toSet();
      expect(colNamesBefore.contains('added_at'), isFalse);

      rawDb.dispose();

      // Step 2: Call initializeDatabase which will run migration v7
      final migratedDb = initializeDatabase(migrationDbPath);

      // Step 3: Verify added_at column now exists in task_items
      final taskItemsCols =
          migratedDb.select("PRAGMA table_info(task_items)");
      final taskItemsColNames =
          taskItemsCols.map((row) => row['name'] as String).toSet();
      expect(taskItemsColNames.contains('added_at'), isTrue);

      // Verify added_at column now exists in slate_items
      final slateItemsCols =
          migratedDb.select("PRAGMA table_info(slate_items)");
      final slateItemsColNames =
          slateItemsCols.map((row) => row['name'] as String).toSet();
      expect(slateItemsColNames.contains('added_at'), isTrue);

      // Step 4: Verify the existing task_items row got a default value
      final taskItemRows = migratedDb.select(
        'SELECT added_at FROM task_items WHERE task_id = ?',
        [taskId],
      );
      expect(taskItemRows, hasLength(1));
      expect(taskItemRows.first['added_at'], isNotNull);
      expect(taskItemRows.first['added_at'], isNotEmpty);

      // Step 5: Verify schema version is now 7
      final versionResult = migratedDb.select(
        "SELECT value FROM schema_metadata WHERE key = 'schema_version'",
      );
      expect(versionResult.first['value'], '7');

      // Step 6: Verify that queries using ORDER BY ti.added_at work
      final queryResult = migratedDb.select('''
        SELECT ti.task_id, ti.item_id, ti.added_at
        FROM task_items ti
        ORDER BY ti.added_at DESC
      ''');
      expect(queryResult, hasLength(1));

      migratedDb.dispose();
      await migrationTempDir.delete(recursive: true);
    });

    test('migration is no-op when added_at already exists', () async {
      // Create a fresh database (which already has added_at in both tables)
      final migrationTempDir = await Directory.systemTemp
          .createTemp('planner_migration_v7_noop_test_');
      final migrationDbPath = p.join(migrationTempDir.path, 'test.db');
      final freshDb = initializeDatabase(migrationDbPath);

      // Verify schema version is 7 (fresh db gets latest version)
      final versionResult = freshDb.select(
        "SELECT value FROM schema_metadata WHERE key = 'schema_version'",
      );
      expect(versionResult.first['value'], '7');

      // Verify added_at exists in both tables
      final taskItemsCols =
          freshDb.select("PRAGMA table_info(task_items)");
      final taskItemsColNames =
          taskItemsCols.map((row) => row['name'] as String).toSet();
      expect(taskItemsColNames.contains('added_at'), isTrue);

      final slateItemsCols =
          freshDb.select("PRAGMA table_info(slate_items)");
      final slateItemsColNames =
          slateItemsCols.map((row) => row['name'] as String).toSet();
      expect(slateItemsColNames.contains('added_at'), isTrue);

      freshDb.dispose();
      await migrationTempDir.delete(recursive: true);
    });
  });
}
