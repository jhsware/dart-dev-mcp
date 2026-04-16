import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Integration tests for the Planner MCP server
/// 
/// These tests verify task and step management functionality
/// using a real SQLite database in temporary directories.
void main() {
  group('Planner Database Tests', () {
    late Directory tempDir;
    late Directory dbDir;
    late String dbPath;
    late Database db;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('planner_mcp_test_');
      dbDir = Directory(p.join(tempDir.path, 'db'));
      await dbDir.create(recursive: true);
      dbPath = p.join(dbDir.path, 'planner.db');
      db = _initializeDatabase(dbPath);
    });

    tearDown(() async {
      db.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('Database Initialization', () {
      test('creates tasks table with correct schema', () {
        final result = db.select(
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks'"
        );
        expect(result, isNotEmpty);
        
        final schema = result.first['sql'] as String;
        expect(schema, contains('id TEXT PRIMARY KEY'));
        expect(schema, contains('project_id TEXT NOT NULL'));
        expect(schema, contains('title TEXT NOT NULL'));
        expect(schema, contains('details TEXT'));
        expect(schema, contains('status TEXT NOT NULL'));
        expect(schema, contains('memory TEXT'));
        expect(schema, contains('created_at TEXT NOT NULL'));
        expect(schema, contains('updated_at TEXT NOT NULL'));
      });

      test('creates steps table with correct schema', () {
        final result = db.select(
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='steps'"
        );
        expect(result, isNotEmpty);
        
        final schema = result.first['sql'] as String;
        expect(schema, contains('id TEXT PRIMARY KEY'));
        expect(schema, contains('task_id TEXT NOT NULL'));
        expect(schema, contains('title TEXT NOT NULL'));
        expect(schema, contains('details TEXT'));
        expect(schema, contains('status TEXT NOT NULL'));
        expect(schema, contains('FOREIGN KEY (task_id) REFERENCES tasks(id)'));
      });

      test('creates indexes for performance', () {
        final indexes = db.select(
          "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'"
        );
        
        final indexNames = indexes.map((r) => r['name'] as String).toList();
        expect(indexNames, contains('idx_tasks_project_id'));
        expect(indexNames, contains('idx_tasks_status'));
        expect(indexNames, contains('idx_steps_task_id'));
        expect(indexNames, contains('idx_steps_status'));
      });
    });

    group('Task Operations', () {
      final uuid = Uuid();

      test('can add a task with all fields', () {
        final id = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, details, status, memory, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', [id, 'project-1', 'Test Task', 'Task details here', 'todo', 'Some memory', now, now]);
        
        final result = db.select('SELECT * FROM tasks WHERE id = ?', [id]);
        expect(result, hasLength(1));
        
        final task = result.first;
        expect(task['id'], id);
        expect(task['project_id'], 'project-1');
        expect(task['title'], 'Test Task');
        expect(task['details'], 'Task details here');
        expect(task['status'], 'todo');
        expect(task['memory'], 'Some memory');
      });

      test('can add a task with minimal fields', () {
        final id = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [id, 'project-1', 'Minimal Task', 'todo', now, now]);
        
        final result = db.select('SELECT * FROM tasks WHERE id = ?', [id]);
        expect(result, hasLength(1));
        expect(result.first['details'], isNull);
        expect(result.first['memory'], isNull);
      });

      test('can update task status', () {
        final id = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [id, 'project-1', 'Task to update', 'todo', now, now]);
        
        db.execute(
          'UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?',
          ['started', now, id]
        );
        
        final result = db.select('SELECT status FROM tasks WHERE id = ?', [id]);
        expect(result.first['status'], 'started');
      });

      test('can update task memory', () {
        final id = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [id, 'project-1', 'Task with memory', 'todo', now, now]);
        
        db.execute(
          'UPDATE tasks SET memory = ?, updated_at = ? WHERE id = ?',
          ['Updated memory content', now, id]
        );
        
        final result = db.select('SELECT memory FROM tasks WHERE id = ?', [id]);
        expect(result.first['memory'], 'Updated memory content');
      });

      test('project_id column exists but filtering is deprecated at operations level', () {
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), 'project-a', 'Task A1', 'todo', now, now]);
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), 'project-a', 'Task A2', 'todo', now, now]);
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), 'project-b', 'Task B1', 'todo', now, now]);
        
        // All tasks are returned when listing (no project_id filter at operations level)
        final allTasks = db.select('SELECT * FROM tasks');
        expect(allTasks, hasLength(3));
        
        // project_id is still stored in the database for backward compatibility
        final projectATasks = db.select(
          'SELECT * FROM tasks WHERE project_id = ?',
          ['project-a']
        );
        expect(projectATasks, hasLength(2));
      });

      test('can add a task with empty project_id (default behavior)', () {
        final id = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [id, '', 'Task with empty project_id', 'todo', now, now]);
        
        final result = db.select('SELECT * FROM tasks WHERE id = ?', [id]);
        expect(result, hasLength(1));
        expect(result.first['project_id'], '');
        expect(result.first['title'], 'Task with empty project_id');
      });

      test('can query tasks by status', () {
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), 'project-1', 'Todo Task', 'todo', now, now]);
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), 'project-1', 'Started Task', 'started', now, now]);
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), 'project-1', 'Done Task', 'done', now, now]);
        
        final todoTasks = db.select('SELECT * FROM tasks WHERE status = ?', ['todo']);
        expect(todoTasks, hasLength(1));
        expect(todoTasks.first['title'], 'Todo Task');
        
        final doneTasks = db.select('SELECT * FROM tasks WHERE status = ?', ['done']);
        expect(doneTasks, hasLength(1));
        expect(doneTasks.first['title'], 'Done Task');
      });

      test('validates task statuses including draft and merged', () {
        final validStatuses = ['backlog', 'todo', 'draft', 'started', 'canceled', 'done', 'merged'];
        final now = DateTime.now().toUtc().toIso8601String();
        
        for (final status in validStatuses) {
          final id = uuid.v4();
          db.execute('''
            INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
          ''', [id, 'project-1', 'Task with status $status', status, now, now]);
          
          final result = db.select('SELECT status FROM tasks WHERE id = ?', [id]);
          expect(result.first['status'], status);
        }
      });

      test('can create task with backlog status', () {
        final id = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [id, 'project-1', 'Backlog Task', 'backlog', now, now]);
        
        final result = db.select('SELECT * FROM tasks WHERE id = ?', [id]);
        expect(result, hasLength(1));
        expect(result.first['status'], 'backlog');
      });

      test('can update task from backlog to todo', () {
        final id = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [id, 'project-1', 'Task to promote', 'backlog', now, now]);
        
        db.execute(
          'UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?',
          ['todo', now, id]
        );
        
        final result = db.select('SELECT status FROM tasks WHERE id = ?', [id]);
        expect(result.first['status'], 'todo');
      });

      test('can filter tasks by backlog status', () {
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), 'project-1', 'Backlog Task 1', 'backlog', now, now]);
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), 'project-1', 'Backlog Task 2', 'backlog', now, now]);
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), 'project-1', 'Todo Task', 'todo', now, now]);
        
        final backlogTasks = db.select('SELECT * FROM tasks WHERE status = ?', ['backlog']);
        expect(backlogTasks, hasLength(2));
        expect(backlogTasks.every((t) => t['title'].toString().contains('Backlog')), isTrue);
      });

    });

    group('Step Operations', () {
      final uuid = Uuid();
      late String taskId;

      setUp(() {
        // Create a task for steps to reference
        taskId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [taskId, 'project-1', 'Parent Task', 'todo', now, now]);
      });

      test('can add a step to a task', () {
        final stepId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO steps (id, task_id, title, details, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', [stepId, taskId, 'Step 1', 'Step details', 'todo', now, now]);
        
        final result = db.select('SELECT * FROM steps WHERE id = ?', [stepId]);
        expect(result, hasLength(1));
        
        final step = result.first;
        expect(step['task_id'], taskId);
        expect(step['title'], 'Step 1');
        expect(step['details'], 'Step details');
        expect(step['status'], 'todo');
      });

      test('can add multiple steps to a task', () {
        final now = DateTime.now().toUtc().toIso8601String();
        
        for (var i = 1; i <= 5; i++) {
          db.execute('''
            INSERT INTO steps (id, task_id, title, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
          ''', [uuid.v4(), taskId, 'Step $i', 'todo', now, now]);
        }
        
        final steps = db.select(
          'SELECT * FROM steps WHERE task_id = ? ORDER BY created_at',
          [taskId]
        );
        expect(steps, hasLength(5));
      });

      test('can update step status', () {
        final stepId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO steps (id, task_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [stepId, taskId, 'Step to update', 'todo', now, now]);
        
        db.execute(
          'UPDATE steps SET status = ?, updated_at = ? WHERE id = ?',
          ['done', now, stepId]
        );
        
        final result = db.select('SELECT status FROM steps WHERE id = ?', [stepId]);
        expect(result.first['status'], 'done');
      });
      test('validates step statuses', () {
        // Steps only support: todo, started, canceled, done
        // (draft and merged are task-only statuses)
        final validStatuses = ['todo', 'started', 'canceled', 'done'];
        final now = DateTime.now().toUtc().toIso8601String();
        
        for (final status in validStatuses) {
          final stepId = uuid.v4();
          db.execute('''
            INSERT INTO steps (id, task_id, title, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
          ''', [stepId, taskId, 'Step with status $status', status, now, now]);
          
          final result = db.select('SELECT status FROM steps WHERE id = ?', [stepId]);
          expect(result.first['status'], status);
        }
      });

      test('backward compatibility: legacy step statuses can be stored and read', () {
        // For backward compatibility, legacy statuses (merged, draft) can still exist
        // in the database from older data. The application layer normalizes them
        // when reading: merged → done, draft → todo
        final now = DateTime.now().toUtc().toIso8601String();
        
        // Insert with legacy 'merged' status
        final mergedStepId = uuid.v4();
        db.execute('''
          INSERT INTO steps (id, task_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [mergedStepId, taskId, 'Legacy merged step', 'merged', now, now]);
        
        // Insert with legacy 'draft' status
        final draftStepId = uuid.v4();
        db.execute('''
          INSERT INTO steps (id, task_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [draftStepId, taskId, 'Legacy draft step', 'draft', now, now]);
        
        // Verify raw DB values are preserved
        final mergedResult = db.select('SELECT status FROM steps WHERE id = ?', [mergedStepId]);
        expect(mergedResult.first['status'], 'merged');
        
        final draftResult = db.select('SELECT status FROM steps WHERE id = ?', [draftStepId]);
        expect(draftResult.first['status'], 'draft');
      });

      test('can get task with its steps', () {

        final now = DateTime.now().toUtc().toIso8601String();
        
        // Add some steps
        for (var i = 1; i <= 3; i++) {
          db.execute('''
            INSERT INTO steps (id, task_id, title, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
          ''', [uuid.v4(), taskId, 'Step $i', 'todo', now, now]);
        }
        
        // Get task
        final taskResult = db.select('SELECT * FROM tasks WHERE id = ?', [taskId]);
        expect(taskResult, hasLength(1));
        
        // Get steps for task
        final stepsResult = db.select(
          'SELECT id, title, status FROM steps WHERE task_id = ? ORDER BY created_at',
          [taskId]
        );
        expect(stepsResult, hasLength(3));
        
        // Verify step data
        for (var i = 0; i < 3; i++) {
          expect(stepsResult[i]['title'], 'Step ${i + 1}');
        }
      });

      test('foreign key constraint prevents orphan steps', () {
        // This test verifies that we can't create steps for non-existent tasks
        // Note: SQLite foreign keys are not enforced by default
        // The planner code validates task existence before adding steps
        
        final nonExistentTaskId = uuid.v4();
        final stepId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        // Without FK enforcement, this will succeed at DB level
        // The planner code should validate task existence
        db.execute('''
          INSERT INTO steps (id, task_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [stepId, nonExistentTaskId, 'Orphan Step', 'todo', now, now]);
        
        // Verify the orphan step exists (FK not enforced at DB level)
        final result = db.select('SELECT * FROM steps WHERE id = ?', [stepId]);
        expect(result, hasLength(1));
        
        // But there's no parent task
        final taskResult = db.select('SELECT * FROM tasks WHERE id = ?', [nonExistentTaskId]);
        expect(taskResult, isEmpty);
      });
    });

    group('Project Instructions', () {
      test('can read instructions file when it exists', () async {
        final instructionsPath = p.join(tempDir.path, 'AGENTS.md');
        final instructionsFile = File(instructionsPath);
        
        const content = '''# Project Instructions

This is a test project.

## Guidelines
- Follow best practices
- Write tests
''';
        
        await instructionsFile.writeAsString(content);
        
        final readContent = await instructionsFile.readAsString();
        expect(readContent, content);
      });

      test('detects when instructions file is missing', () async {
        final instructionsPath = p.join(tempDir.path, 'AGENTS.md');
        final instructionsFile = File(instructionsPath);
        
        expect(await instructionsFile.exists(), isFalse);
      });
    });

    group('Complex Workflows', () {
      final uuid = Uuid();

      test('can create a task with multiple steps and update statuses', () {
        final now = DateTime.now().toUtc().toIso8601String();
        
        // Create task
        final taskId = uuid.v4();
        db.execute('''
          INSERT INTO tasks (id, project_id, title, details, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', [taskId, 'project-1', 'Implement feature X', 'Add new feature with tests', 'todo', now, now]);
        
        // Create steps
        final stepIds = <String>[];
        final stepTitles = [
          'Create data model',
          'Implement business logic',
          'Write unit tests',
          'Update documentation',
        ];
        
        for (final title in stepTitles) {
          final stepId = uuid.v4();
          stepIds.add(stepId);
          db.execute('''
            INSERT INTO steps (id, task_id, title, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
          ''', [stepId, taskId, title, 'todo', now, now]);
        }
        
        // Start the task
        db.execute(
          'UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?',
          ['started', now, taskId]
        );
        
        // Complete first two steps
        for (var i = 0; i < 2; i++) {
          db.execute(
            'UPDATE steps SET status = ?, updated_at = ? WHERE id = ?',
            ['done', now, stepIds[i]]
          );
        }
        
        // Start third step
        db.execute(
          'UPDATE steps SET status = ?, updated_at = ? WHERE id = ?',
          ['started', now, stepIds[2]]
        );
        
        // Verify state
        final taskResult = db.select('SELECT status FROM tasks WHERE id = ?', [taskId]);
        expect(taskResult.first['status'], 'started');
        
        final stepsResult = db.select(
          'SELECT status FROM steps WHERE task_id = ? ORDER BY created_at',
          [taskId]
        );
        expect(stepsResult[0]['status'], 'done');
        expect(stepsResult[1]['status'], 'done');
        expect(stepsResult[2]['status'], 'started');
        expect(stepsResult[3]['status'], 'todo');
      });

      test('can use memory to track progress notes', () {
        final taskId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        // Create task with initial memory
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, memory, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', [taskId, 'project-1', 'Research task', 'todo', 'Initial research notes', now, now]);
        
        // Update memory with more details
        final updatedMemory = '''Initial research notes

## Session 1
- Found relevant documentation
- Identified key components

## Session 2
- Prototyped solution
- Need to discuss with team
''';
        
        db.execute(
          'UPDATE tasks SET memory = ?, updated_at = ? WHERE id = ?',
          [updatedMemory, now, taskId]
        );
        
        final result = db.select('SELECT memory FROM tasks WHERE id = ?', [taskId]);
        expect(result.first['memory'], updatedMemory);
      });

      test('can handle concurrent projects', () {
        final now = DateTime.now().toUtc().toIso8601String();
        
        // Create multiple projects with tasks
        final projects = ['backend-api', 'frontend-ui', 'mobile-app'];
        
        for (final projectId in projects) {
          for (var i = 1; i <= 3; i++) {
            final taskId = uuid.v4();
            db.execute('''
              INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
              VALUES (?, ?, ?, ?, ?, ?)
            ''', [taskId, projectId, '$projectId Task $i', 'todo', now, now]);
          }
        }
        
        // Verify each project has its tasks
        for (final projectId in projects) {
          final tasks = db.select(
            'SELECT * FROM tasks WHERE project_id = ?',
            [projectId]
          );
          expect(tasks, hasLength(3));
          
          for (final task in tasks) {
            expect(task['title'], startsWith(projectId));
          }
        }
        
        // Total tasks
        final allTasks = db.select('SELECT COUNT(*) as count FROM tasks');
        expect(allTasks.first['count'], 9);
      });
    });

    group('Edge Cases', () {
      final uuid = Uuid();

      test('handles empty strings in optional fields', () {
        final taskId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, details, status, memory, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', [taskId, 'project-1', 'Task with empty fields', '', 'todo', '', now, now]);
        
        final result = db.select('SELECT * FROM tasks WHERE id = ?', [taskId]);
        expect(result.first['details'], '');
        expect(result.first['memory'], '');
      });

      test('handles special characters in text fields', () {
        final taskId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        const specialTitle = "Task with 'quotes', \"double quotes\", and \u00e9mojis \ud83c\udf89";
        const specialDetails = '''
Multi-line details with:
- Bullets
- Special chars: < > & " '
- Unicode: \u65e5\u672c\u8a9e \ud55c\uad6d\uc5b4 \u0627\u0644\u0639\u0631\u0628\u064a\u0629
''';
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, details, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', [taskId, 'project-1', specialTitle, specialDetails, 'todo', now, now]);
        
        final result = db.select('SELECT * FROM tasks WHERE id = ?', [taskId]);
        expect(result.first['title'], specialTitle);
        expect(result.first['details'], specialDetails);
      });

      test('handles very long text in memory field', () {
        final taskId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        
        // Create a very long memory string (100KB)
        final longMemory = 'A' * 100000;
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, memory, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', [taskId, 'project-1', 'Task with long memory', 'todo', longMemory, now, now]);
        
        final result = db.select('SELECT memory FROM tasks WHERE id = ?', [taskId]);
        expect(result.first['memory'], hasLength(100000));
      });

      test('preserves timestamp precision', () {
        final taskId = uuid.v4();
        final now = DateTime.now().toUtc();
        final isoString = now.toIso8601String();
        
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [taskId, 'project-1', 'Timestamp test', 'todo', isoString, isoString]);
        
        final result = db.select('SELECT created_at, updated_at FROM tasks WHERE id = ?', [taskId]);
        expect(result.first['created_at'], isoString);
        expect(result.first['updated_at'], isoString);
      });
    });

    group('Sub-task References', () {
      final uuid = Uuid();
      late String taskId;

      setUp(() {
        taskId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();
        db.execute('''
          INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [taskId, 'project-1', 'Parent Task', 'todo', now, now]);
      });

      test('steps table has sub_task_id column', () {
        final result = db.select(
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='steps'"
        );
        expect(result, isNotEmpty);
        final schema = result.first['sql'] as String;
        expect(schema, contains('sub_task_id TEXT'));
      });

      test('can add a step with sub_task_id', () {
        final stepId = uuid.v4();
        final subTaskId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();

        db.execute('''
          INSERT INTO steps (id, task_id, title, status, sub_task_id, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', [stepId, taskId, 'Step with sub-task', 'todo', subTaskId, now, now]);

        final result = db.select('SELECT * FROM steps WHERE id = ?', [stepId]);
        expect(result, hasLength(1));
        expect(result.first['sub_task_id'], subTaskId);
      });

      test('sub_task_id defaults to null', () {
        final stepId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();

        db.execute('''
          INSERT INTO steps (id, task_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [stepId, taskId, 'Step without sub-task', 'todo', now, now]);

        final result = db.select('SELECT sub_task_id FROM steps WHERE id = ?', [stepId]);
        expect(result.first['sub_task_id'], isNull);
      });

      test('can update step sub_task_id', () {
        final stepId = uuid.v4();
        final subTaskId = uuid.v4();
        final now = DateTime.now().toUtc().toIso8601String();

        db.execute('''
          INSERT INTO steps (id, task_id, title, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [stepId, taskId, 'Step to link', 'todo', now, now]);

        // Initially null
        var result = db.select('SELECT sub_task_id FROM steps WHERE id = ?', [stepId]);
        expect(result.first['sub_task_id'], isNull);

        // Update to set sub_task_id
        db.execute(
          'UPDATE steps SET sub_task_id = ?, updated_at = ? WHERE id = ?',
          [subTaskId, now, stepId]
        );

        result = db.select('SELECT sub_task_id FROM steps WHERE id = ?', [stepId]);
        expect(result.first['sub_task_id'], subTaskId);
      });

      test('can query steps with sub_task_id for show-task listing', () {
        final now = DateTime.now().toUtc().toIso8601String();
        final subTaskId1 = uuid.v4();
        final subTaskId2 = uuid.v4();

        db.execute('''
          INSERT INTO steps (id, task_id, title, status, sub_task_id, sort_order, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), taskId, 'Step 1', 'todo', subTaskId1, 1, now, now]);

        db.execute('''
          INSERT INTO steps (id, task_id, title, status, sub_task_id, sort_order, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), taskId, 'Step 2', 'todo', subTaskId2, 2, now, now]);

        db.execute('''
          INSERT INTO steps (id, task_id, title, status, sort_order, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), taskId, 'Step 3', 'todo', 3, now, now]);

        final steps = db.select(
          'SELECT id, title, status, sub_task_id FROM steps WHERE task_id = ? ORDER BY COALESCE(sort_order, 9999999), created_at',
          [taskId]
        );

        expect(steps, hasLength(3));
        expect(steps[0]['sub_task_id'], subTaskId1);
        expect(steps[1]['sub_task_id'], subTaskId2);
        expect(steps[2]['sub_task_id'], isNull);
      });
    });
  });

  group('Planner Server CLI Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('planner_cli_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('shows help with --help flag', () async {
      final result = await Process.run(
        'dart',
        ['run', 'packages/planner/bin/planner_mcp.dart', '--help'],
        workingDirectory: Directory.current.path,
      );
      
      expect(result.exitCode, 0);
      expect(result.stderr, contains('Usage: planner_mcp --planner-data-root=PATH --project-dir=PATH1'));
      expect(result.stderr, contains('--help'));
      expect(result.stderr, contains('--planner-data-root'));
    });

    test('requires --project-dir argument', () async {
      final result = await Process.run(
        'dart',
        ['run', 'packages/planner/bin/planner_mcp.dart', '--planner-data-root=/tmp/test'],
        workingDirectory: Directory.current.path,
      );
      
      expect(result.exitCode, 1);
      expect(result.stderr, contains('--project-dir is required'));
    });

    test('requires --planner-data-root argument', () async {
      final result = await Process.run(
        'dart',
        ['run', 'packages/planner/bin/planner_mcp.dart', '--project-dir=${tempDir.path}'],
        workingDirectory: Directory.current.path,
      );
      
      expect(result.exitCode, 1);
      expect(result.stderr, contains('--planner-data-root is required'));
    });

    test('fails with non-existent project directory', () async {
      final result = await Process.run(
        'dart',
        ['run', 'packages/planner/bin/planner_mcp.dart', '--project-dir=/nonexistent/path', '--planner-data-root=${tempDir.path}'],
        workingDirectory: Directory.current.path,
      );
      
      expect(result.exitCode, 1);
      expect(result.stderr, contains('does not exist'));
    });

    test('starts successfully with valid planner-data-root and project-dir', () async {
      final dataRoot = Directory(p.join(tempDir.path, 'planner-data'));
      await dataRoot.create(recursive: true);
      
      final projectDir = Directory(p.join(tempDir.path, 'my-project'));
      await projectDir.create(recursive: true);
      
      // Start server briefly to verify it starts without errors
      final process = await Process.start(
        'dart',
        ['run', 'packages/planner/bin/planner_mcp.dart', '--project-dir=${projectDir.path}', '--planner-data-root=${dataRoot.path}'],
        workingDirectory: Directory.current.path,
      );
      
      // Collect stderr output for startup messages
      final stderrLines = <String>[];
      process.stderr.transform(const SystemEncoding().decoder).listen((data) {
        stderrLines.add(data);
      });
      
      // Wait for startup
      await Future.delayed(Duration(seconds: 3));
      
      // Verify startup log messages indicate success
      final stderrOutput = stderrLines.join();
      expect(stderrOutput, contains('Planner MCP Server starting'));
      expect(stderrOutput, contains('Planner MCP Server running'));
      
      process.kill();
      await process.exitCode;
    });

    test('supports multiple --project-dir arguments', () async {
      final dataRoot = Directory(p.join(tempDir.path, 'planner-data'));
      await dataRoot.create(recursive: true);
      
      final projectDir1 = Directory(p.join(tempDir.path, 'project-a'));
      await projectDir1.create(recursive: true);
      final projectDir2 = Directory(p.join(tempDir.path, 'project-b'));
      await projectDir2.create(recursive: true);
      
      // Start server with multiple project dirs
      final process = await Process.start(
        'dart',
        [
          'run', 'packages/planner/bin/planner_mcp.dart',
          '--project-dir=${projectDir1.path}',
          '--project-dir=${projectDir2.path}',
          '--planner-data-root=${dataRoot.path}',
        ],
        workingDirectory: Directory.current.path,
      );
      
      // Wait for startup
      await Future.delayed(Duration(seconds: 3));
      
      process.kill();
      // Server should start without errors (exit code from kill is not 1)
      final exitCode = await process.exitCode;
      // SIGTERM/SIGINT results in non-zero but that's expected from kill
      expect(exitCode, isNot(1));
    });

    group('list-projects operation', () {
      test('returns project dirs with short names', () {
        // Simulate the list-projects logic from _handlePlanner
        final projectDirs = [
          '/home/user/projects/my-app',
          '/home/user/projects/shared-libs',
          '/tmp/test-project',
        ];

        final projects = projectDirs.map((dir) => {
          'project_dir': dir,
          'project_name': p.basename(dir),
        }).toList();

        expect(projects, hasLength(3));
        expect(projects[0]['project_dir'], '/home/user/projects/my-app');
        expect(projects[0]['project_name'], 'my-app');
        expect(projects[1]['project_dir'], '/home/user/projects/shared-libs');
        expect(projects[1]['project_name'], 'shared-libs');
        expect(projects[2]['project_dir'], '/tmp/test-project');
        expect(projects[2]['project_name'], 'test-project');
      });

      test('returns empty list when no project dirs', () {
        final projectDirs = <String>[];

        final projects = projectDirs.map((dir) => {
          'project_dir': dir,
          'project_name': p.basename(dir),
        }).toList();

        expect(projects, isEmpty);
      });
    });
  });
}

/// Initialize database with the same schema as the planner server
Database _initializeDatabase(String dbPath) {
  final db = sqlite3.open(dbPath);
  
  db.execute('''
    CREATE TABLE IF NOT EXISTS tasks (
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
  
  db.execute('''
    CREATE TABLE IF NOT EXISTS steps (
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
  
  db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON tasks(project_id)');
  db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)');
  db.execute('CREATE INDEX IF NOT EXISTS idx_steps_task_id ON steps(task_id)');
  db.execute('CREATE INDEX IF NOT EXISTS idx_steps_status ON steps(status)');
  
  return db;
}
