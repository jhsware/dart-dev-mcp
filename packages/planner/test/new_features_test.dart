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

    test('uses task project_id for log entry', () {
      final taskId = createTask('My task', projectId: 'my-project');

      final result = gitLogOps.logCommit({
        'commit_hash': 'abc123',
        'branch': 'main',
        'task_id': taskId,
      });

      final data = parseResult(result);
      final logs = db.select(
        'SELECT project_id FROM transaction_logs WHERE id = ?',
        [data['log_entry_id']],
      );
      expect(logs.first['project_id'], 'my-project');
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
}
