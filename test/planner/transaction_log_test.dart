import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:dart_dev_mcp/planner/planner.dart';


/// Tests for the transaction log system.
///
/// This covers:
/// - Data models (TransactionLogEntry, enums)
/// - Repository operations (log, getTimeline, getAuditTrail)
/// - Summary generation and diff calculation
void main() {
  group('Transaction Log Data Model', () {
    group('TransactionType', () {
      test('converts to database value correctly', () {
        expect(TransactionType.create.toDbValue(), 'create');
        expect(TransactionType.update.toDbValue(), 'update');
        expect(TransactionType.delete.toDbValue(), 'delete');
      });

      test('parses from database value correctly', () {
        expect(TransactionType.fromDbValue('create'), TransactionType.create);
        expect(TransactionType.fromDbValue('update'), TransactionType.update);
        expect(TransactionType.fromDbValue('delete'), TransactionType.delete);
      });

      test('throws on invalid database value', () {
        expect(
          () => TransactionType.fromDbValue('invalid'),
          throwsArgumentError,
        );
      });
    });

    group('EntityType', () {
      test('converts to database value correctly', () {
        expect(EntityType.task.toDbValue(), 'task');
        expect(EntityType.step.toDbValue(), 'step');
      });

      test('parses from database value correctly', () {
        expect(EntityType.fromDbValue('task'), EntityType.task);
        expect(EntityType.fromDbValue('step'), EntityType.step);
      });

      test('throws on invalid database value', () {
        expect(
          () => EntityType.fromDbValue('invalid'),
          throwsArgumentError,
        );
      });
    });

    group('TransactionLogEntry', () {
      test('creates from row correctly', () {
        final row = {
          'id': 'test-id',
          'created_at': '2025-01-01T12:00:00.000Z',
          'entity_type': 'task',
          'entity_id': 'task-123',
          'transaction_type': 'create',
          'summary': "Task 'Test' created",
          'changes': '{"before":null,"after":{"title":"Test"}}',
          'project_id': 'project-1',
        };

        final entry = TransactionLogEntry.fromRow(row);

        expect(entry.id, 'test-id');
        expect(entry.entityType, EntityType.task);
        expect(entry.entityId, 'task-123');
        expect(entry.transactionType, TransactionType.create);
        expect(entry.summary, "Task 'Test' created");
        expect(entry.changes, {'before': null, 'after': {'title': 'Test'}});
        expect(entry.projectId, 'project-1');
      });

      test('handles null changes JSON', () {
        final row = {
          'id': 'test-id',
          'created_at': '2025-01-01T12:00:00.000Z',
          'entity_type': 'task',
          'entity_id': 'task-123',
          'transaction_type': 'create',
          'summary': "Task 'Test' created",
          'changes': null,
          'project_id': null,
        };

        final entry = TransactionLogEntry.fromRow(row);

        expect(entry.changes, isNull);
        expect(entry.projectId, isNull);
      });

      test('toJson includes all fields', () {
        final entry = TransactionLogEntry(
          id: 'test-id',
          timestamp: DateTime.utc(2025, 1, 1, 12, 0, 0),
          entityType: EntityType.task,
          entityId: 'task-123',
          transactionType: TransactionType.update,
          summary: "Task 'Test' updated",
          changes: {'before': {'status': 'todo'}, 'after': {'status': 'done'}},
          projectId: 'project-1',
        );

        final json = entry.toJson();

        expect(json['id'], 'test-id');
        expect(json['timestamp'], '2025-01-01T12:00:00.000Z');
        expect(json['entity_type'], 'task');
        expect(json['entity_id'], 'task-123');
        expect(json['transaction_type'], 'update');
        expect(json['summary'], "Task 'Test' updated");
        expect(json['changes'], isNotNull);
        expect(json['project_id'], 'project-1');
      });

      test('toTimelineJson excludes changes', () {
        final entry = TransactionLogEntry(
          id: 'test-id',
          timestamp: DateTime.utc(2025, 1, 1, 12, 0, 0),
          entityType: EntityType.task,
          entityId: 'task-123',
          transactionType: TransactionType.update,
          summary: "Task 'Test' updated",
          changes: {'before': {'status': 'todo'}, 'after': {'status': 'done'}},
          projectId: 'project-1',
        );

        final json = entry.toTimelineJson();

        expect(json.containsKey('changes'), isFalse);
        expect(json['id'], 'test-id');
        expect(json['summary'], "Task 'Test' updated");
      });
    });
  });

  group('Transaction Log Repository', () {
    late Directory tempDir;
    late Database db;
    late TransactionLogRepository repo;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('txlog_test_');
      final dbPath = p.join(tempDir.path, 'test.db');
      db = sqlite3.open(dbPath);
      repo = TransactionLogRepository(db);
      repo.initializeTable();
    });

    tearDown(() async {
      db.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('initializeTable', () {
      test('creates transaction_logs table', () {
        final result = db.select(
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='transaction_logs'",
        );
        expect(result, isNotEmpty);

        final schema = result.first['sql'] as String;
        expect(schema, contains('id TEXT PRIMARY KEY'));
        expect(schema, contains('entity_type TEXT NOT NULL'));
        expect(schema, contains('entity_id TEXT NOT NULL'));
        expect(schema, contains('transaction_type TEXT NOT NULL'));
        expect(schema, contains('summary TEXT NOT NULL'));
        expect(schema, contains('changes TEXT'));
        expect(schema, contains('project_id TEXT'));
        expect(schema, contains('created_at TEXT NOT NULL'));
      });

      test('creates required indexes', () {
        final indexes = db.select(
          "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_transaction_logs%'",
        );

        final indexNames = indexes.map((r) => r['name'] as String).toList();
        expect(indexNames, contains('idx_transaction_logs_created_at'));
        expect(indexNames, contains('idx_transaction_logs_entity'));
        expect(indexNames, contains('idx_transaction_logs_project'));
        expect(indexNames, contains('idx_transaction_logs_project_time'));
      });
    });

    group('log', () {
      test('creates entry with all fields', () {
        final entry = repo.log(
          entityType: EntityType.task,
          entityId: 'task-123',
          transactionType: TransactionType.create,
          summary: "Task 'Test' created",
          changes: {'before': null, 'after': {'title': 'Test'}},
          projectId: 'project-1',
        );

        expect(entry.id, isNotEmpty);
        expect(entry.entityType, EntityType.task);
        expect(entry.entityId, 'task-123');
        expect(entry.transactionType, TransactionType.create);
        expect(entry.summary, "Task 'Test' created");
        expect(entry.changes, isNotNull);
        expect(entry.projectId, 'project-1');
      });

      test('stores entry in database', () {
        final entry = repo.log(
          entityType: EntityType.task,
          entityId: 'task-123',
          transactionType: TransactionType.create,
          summary: "Task 'Test' created",
        );

        final result = db.select(
          'SELECT * FROM transaction_logs WHERE id = ?',
          [entry.id],
        );

        expect(result, hasLength(1));
        expect(result.first['entity_type'], 'task');
        expect(result.first['entity_id'], 'task-123');
      });

      test('handles null optional fields', () {
        final entry = repo.log(
          entityType: EntityType.step,
          entityId: 'step-456',
          transactionType: TransactionType.update,
          summary: "Step 'Test' updated",
        );

        expect(entry.changes, isNull);
        expect(entry.projectId, isNull);

        final result = db.select(
          'SELECT changes, project_id FROM transaction_logs WHERE id = ?',
          [entry.id],
        );

        expect(result.first['changes'], isNull);
        expect(result.first['project_id'], isNull);
      });
    });

    group('getTimeline', () {
      setUp(() {
        // Create test entries with different timestamps
        for (var i = 1; i <= 10; i++) {
          final timestamp = DateTime.utc(2025, 1, i).toIso8601String();
          db.execute('''
            INSERT INTO transaction_logs 
              (id, entity_type, entity_id, transaction_type, summary, project_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
          ''', [
            'entry-$i',
            i <= 5 ? 'task' : 'step',
            'entity-$i',
            i % 3 == 0 ? 'update' : 'create',
            'Entry $i',
            i <= 3 ? 'project-a' : 'project-b',
            timestamp,
          ]);
        }
      });

      test('returns entries in reverse chronological order by default', () {
        final entries = repo.getTimeline(TransactionLogQuery(limit: 10));

        expect(entries, hasLength(10));
        expect(entries.first.id, 'entry-10'); // Most recent
        expect(entries.last.id, 'entry-1'); // Oldest
      });

      test('filters by entity type', () {
        final entries = repo.getTimeline(
          TransactionLogQuery(entityType: EntityType.task, limit: 10),
        );

        expect(entries, hasLength(5));
        for (final entry in entries) {
          expect(entry.entityType, EntityType.task);
        }
      });

      test('filters by project', () {
        final entries = repo.getTimeline(
          TransactionLogQuery(projectId: 'project-a', limit: 10),
        );

        expect(entries, hasLength(3));
        for (final entry in entries) {
          expect(entry.projectId, 'project-a');
        }
      });

      test('filters by time range', () {
        final entries = repo.getTimeline(
          TransactionLogQuery(
            after: DateTime.utc(2025, 1, 3),
            before: DateTime.utc(2025, 1, 8),
            limit: 10,
          ),
        );

        expect(entries, hasLength(4)); // entries 4, 5, 6, 7
      });

      test('respects limit', () {
        final entries = repo.getTimeline(TransactionLogQuery(limit: 3));

        expect(entries, hasLength(3));
      });

      test('supports pagination with offset', () {
        final page1 = repo.getTimeline(TransactionLogQuery(limit: 3, offset: 0));
        final page2 = repo.getTimeline(TransactionLogQuery(limit: 3, offset: 3));

        expect(page1.map((e) => e.id), ['entry-10', 'entry-9', 'entry-8']);
        expect(page2.map((e) => e.id), ['entry-7', 'entry-6', 'entry-5']);
      });

      test('supports oldest-first ordering', () {
        final entries = repo.getTimeline(
          TransactionLogQuery(limit: 3, newestFirst: false),
        );

        expect(entries.first.id, 'entry-1'); // Oldest
        expect(entries.last.id, 'entry-3');
      });
    });

    group('getAuditTrail', () {
      setUp(() {
        final uuid = const Uuid();
        final taskId = 'task-audit-test';

        // Create multiple transactions for the same entity
        for (var i = 1; i <= 5; i++) {
          final timestamp = DateTime.utc(2025, 1, i).toIso8601String();
          db.execute('''
            INSERT INTO transaction_logs 
              (id, entity_type, entity_id, transaction_type, summary, changes, project_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ''', [
            uuid.v4(),
            'task',
            taskId,
            i == 1 ? 'create' : 'update',
            'Transaction $i for task',
            '{"before":{"status":"${i == 1 ? null : 'status-${i - 1}'}"},"after":{"status":"status-$i"}}',
            'project-1',
            timestamp,
          ]);
        }

        // Add some unrelated entries
        db.execute('''
          INSERT INTO transaction_logs 
            (id, entity_type, entity_id, transaction_type, summary, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [uuid.v4(), 'step', 'other-step', 'create', 'Other entry', DateTime.now().toIso8601String()]);
      });

      test('returns all transactions for specific entity', () {
        final entries = repo.getAuditTrail(
          entityType: EntityType.task,
          entityId: 'task-audit-test',
        );

        expect(entries, hasLength(5));
        for (final entry in entries) {
          expect(entry.entityId, 'task-audit-test');
        }
      });

      test('includes full change details', () {
        final entries = repo.getAuditTrail(
          entityType: EntityType.task,
          entityId: 'task-audit-test',
          limit: 1,
        );

        expect(entries, hasLength(1));
        expect(entries.first.changes, isNotNull);
        expect(entries.first.changes!['after'], isNotNull);
      });

      test('orders by timestamp', () {
        final entriesDesc = repo.getAuditTrail(
          entityType: EntityType.task,
          entityId: 'task-audit-test',
          newestFirst: true,
        );

        final entriesAsc = repo.getAuditTrail(
          entityType: EntityType.task,
          entityId: 'task-audit-test',
          newestFirst: false,
        );

        expect(entriesDesc.first.transactionType, TransactionType.update);
        expect(entriesAsc.first.transactionType, TransactionType.create);
      });

      test('returns empty list for non-existent entity', () {
        final entries = repo.getAuditTrail(
          entityType: EntityType.task,
          entityId: 'non-existent',
        );

        expect(entries, isEmpty);
      });
    });

    group('count', () {
      setUp(() {
        for (var i = 1; i <= 10; i++) {
          db.execute('''
            INSERT INTO transaction_logs 
              (id, entity_type, entity_id, transaction_type, summary, project_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
          ''', [
            'entry-$i',
            i <= 5 ? 'task' : 'step',
            'entity-$i',
            'create',
            'Entry $i',
            'project-1',
            DateTime.utc(2025, 1, i).toIso8601String(),
          ]);
        }
      });

      test('counts all entries', () {
        final count = repo.count(TransactionLogQuery());
        expect(count, 10);
      });

      test('counts filtered entries', () {
        final count = repo.count(TransactionLogQuery(entityType: EntityType.task));
        expect(count, 5);
      });
    });

    group('deleteOlderThan', () {
      setUp(() {
        for (var i = 1; i <= 10; i++) {
          db.execute('''
            INSERT INTO transaction_logs 
              (id, entity_type, entity_id, transaction_type, summary, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
          ''', [
            'entry-$i',
            'task',
            'task-$i',
            'create',
            'Entry $i',
            DateTime.utc(2025, 1, i).toIso8601String(),
          ]);
        }
      });

      test('deletes entries older than cutoff', () {
        final deleted = repo.deleteOlderThan(DateTime.utc(2025, 1, 6));

        expect(deleted, 5); // entries 1-5

        final remaining = repo.count(TransactionLogQuery());
        expect(remaining, 5);
      });
    });
  });

  group('Transaction Summary', () {
    group('generateSummary', () {
      test('creates summary for task creation', () {
        final summary = generateSummary(
          transactionType: TransactionType.create,
          entityType: EntityType.task,
          entityTitle: 'Fix bug',
          projectId: 'myapp',
        );

        expect(summary, "Task 'Fix bug' created in project 'myapp'");
      });

      test('creates summary for task without project', () {
        final summary = generateSummary(
          transactionType: TransactionType.create,
          entityType: EntityType.task,
          entityTitle: 'Fix bug',
        );

        expect(summary, "Task 'Fix bug' created");
      });

      test('creates summary for step creation', () {
        final summary = generateSummary(
          transactionType: TransactionType.create,
          entityType: EntityType.step,
          entityTitle: 'Write tests',
          taskTitle: 'Fix bug',
        );

        expect(summary, "Step 'Write tests' added to task 'Fix bug'");
      });

      test('creates summary for status update', () {
        final summary = generateSummary(
          transactionType: TransactionType.update,
          entityType: EntityType.task,
          entityTitle: 'Fix bug',
          changes: {
            'before': {'status': 'todo'},
            'after': {'status': 'done'},
          },
        );

        expect(summary, "Task 'Fix bug' status changed from todo to done");
      });

      test('creates summary for title update', () {
        final summary = generateSummary(
          transactionType: TransactionType.update,
          entityType: EntityType.task,
          entityTitle: 'New title',
          changes: {
            'before': {'title': 'Old title'},
            'after': {'title': 'New title'},
          },
        );

        expect(summary, "Task 'New title' title updated");
      });

      test('creates summary for memory update', () {
        final summary = generateSummary(
          transactionType: TransactionType.update,
          entityType: EntityType.task,
          entityTitle: 'My task',
          changes: {
            'before': {'memory': 'old notes'},
            'after': {'memory': 'new notes'},
          },
        );

        expect(summary, "Task 'My task' memory updated");
      });

      test('creates summary for deletion', () {
        final summary = generateSummary(
          transactionType: TransactionType.delete,
          entityType: EntityType.task,
          entityTitle: 'Deleted task',
        );

        expect(summary, "Task 'Deleted task' deleted");
      });

      test('truncates long titles', () {
        final longTitle = 'A' * 100;
        final summary = generateSummary(
          transactionType: TransactionType.create,
          entityType: EntityType.task,
          entityTitle: longTitle,
        );

        expect(summary.length, lessThan(100));
        expect(summary, contains('...'));
      });
    });

    group('calculateChanges', () {
      test('stores all fields for create', () {
        final changes = calculateChanges(
          transactionType: TransactionType.create,
          after: {
            'id': 'task-1',
            'title': 'New task',
            'status': 'todo',
            'project_id': 'project-1',
          },
        );

        expect(changes['before'], isNull);
        expect(changes['after'], isNotNull);
        expect(changes['after']['title'], 'New task');
        expect(changes['after']['status'], 'todo');
      });

      test('stores only changed fields for update', () {
        final changes = calculateChanges(
          transactionType: TransactionType.update,
          before: {
            'id': 'task-1',
            'title': 'Task',
            'status': 'todo',
            'details': 'Some details',
            'updated_at': '2025-01-01T00:00:00Z',
          },
          after: {
            'id': 'task-1',
            'title': 'Task',
            'status': 'done',
            'details': 'Some details',
            'updated_at': '2025-01-02T00:00:00Z',
          },
        );

        // Only status changed (updated_at is skipped)
        expect(changes['before'], {'status': 'todo'});
        expect(changes['after'], {'status': 'done'});
      });

      test('stores final state for delete', () {
        final changes = calculateChanges(
          transactionType: TransactionType.delete,
          before: {
            'id': 'task-1',
            'title': 'Deleted task',
            'status': 'done',
          },
        );

        expect(changes['before'], isNotNull);
        expect(changes['before']['title'], 'Deleted task');
        expect(changes['after'], isNull);
      });

      test('handles multiple field changes', () {
        final changes = calculateChanges(
          transactionType: TransactionType.update,
          before: {
            'title': 'Old title',
            'status': 'todo',
            'details': 'Old details',
          },
          after: {
            'title': 'New title',
            'status': 'started',
            'details': 'New details',
          },
        );

        expect(changes['before']!.length, 3);
        expect(changes['after']!.length, 3);
      });

      test('handles null to value changes', () {
        final changes = calculateChanges(
          transactionType: TransactionType.update,
          before: {'title': 'Task', 'details': null},
          after: {'title': 'Task', 'details': 'Added details'},
        );

        expect(changes['before'], {'details': null});
        expect(changes['after'], {'details': 'Added details'});
      });
    });

    group('taskToLoggable', () {
      test('extracts all task fields', () {
        final task = {
          'id': 'task-1',
          'project_id': 'project-1',
          'title': 'My task',
          'details': 'Task details',
          'status': 'todo',
          'memory': 'Some notes',
          'created_at': '2025-01-01T00:00:00Z',
          'updated_at': '2025-01-02T00:00:00Z',
          'extra_field': 'ignored', // Should be included since we copy all
        };

        final loggable = taskToLoggable(task);

        expect(loggable['id'], 'task-1');
        expect(loggable['project_id'], 'project-1');
        expect(loggable['title'], 'My task');
        expect(loggable['status'], 'todo');
        expect(loggable['memory'], 'Some notes');
        expect(loggable.containsKey('extra_field'), isFalse);
      });
    });

    group('stepToLoggable', () {
      test('extracts all step fields', () {
        final step = {
          'id': 'step-1',
          'task_id': 'task-1',
          'title': 'My step',
          'details': 'Step details',
          'status': 'todo',
          'created_at': '2025-01-01T00:00:00Z',
          'updated_at': '2025-01-02T00:00:00Z',
        };

        final loggable = stepToLoggable(step);

        expect(loggable['id'], 'step-1');
        expect(loggable['task_id'], 'task-1');
        expect(loggable['title'], 'My step');
        expect(loggable['status'], 'todo');
      });
    });
  });
}
