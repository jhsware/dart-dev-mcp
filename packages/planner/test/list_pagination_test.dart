import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:planner_mcp/planner_mcp.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Tests for pagination in list-tasks, list-items, list-slates.
void main() {
  late Directory tempDir;
  late Database db;
  late TransactionLogRepository transactionLogRepo;
  late TaskOperations taskOps;
  late ItemOperations itemOps;
  late SlateOperations slateOps;

  final uuid = Uuid();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('planner_pagination_test_');
    final dbPath = p.join(tempDir.path, 'test.db');
    db = initializeDatabase(dbPath);
    transactionLogRepo = TransactionLogRepository(db);
    transactionLogRepo.initializeTable();
    taskOps = TaskOperations(
      database: db,
      transactionLogRepository: transactionLogRepo,
    );
    itemOps = ItemOperations(
      database: db,
      transactionLogRepository: transactionLogRepo,
    );
    slateOps = SlateOperations(
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

  Map<String, dynamic> parseResult(CallToolResult result) {
    final text = (result.content.first as TextContent).text;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  String resultText(CallToolResult result) {
    return (result.content.first as TextContent).text;
  }

  void seedTasks(int count, {String status = 'todo'}) {
    final now = DateTime.now().toUtc().toIso8601String();
    for (var i = 0; i < count; i++) {
      db.execute('''
        INSERT INTO tasks (id, project_id, title, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
      ''', [uuid.v4(), '', 'Task $i', status, now, now]);
    }
  }

  void seedItems(int count, {String status = 'open', String type = 'feature'}) {
    final now = DateTime.now().toUtc().toIso8601String();
    for (var i = 0; i < count; i++) {
      db.execute('''
        INSERT INTO items (id, project_id, title, type, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      ''', [uuid.v4(), '', 'Item $i', type, status, now, now]);
    }
  }

  void seedSlates(int count, {String status = 'draft'}) {
    final now = DateTime.now().toUtc().toIso8601String();
    for (var i = 0; i < count; i++) {
      db.execute('''
        INSERT INTO slates (id, project_id, title, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
      ''', [uuid.v4(), '', 'Slate $i', status, now, now]);
    }
  }

  group('list-tasks pagination', () {
    test('default paging returns at most 30 items with correct total', () {
      seedTasks(35);

      final data = parseResult(taskOps.listTasks({}));
      expect(data['count'], 30);
      expect(data['total'], 35);
      expect(data['start_at'], 0);
      expect(data['limit'], 30);
      expect(data['has_more'], isTrue);
    });

    test('start_at=30 returns remaining items and has_more=false', () {
      seedTasks(35);

      final data = parseResult(taskOps.listTasks({'start_at': 30}));
      expect(data['count'], 5);
      expect(data['total'], 35);
      expect(data['start_at'], 30);
      expect(data['has_more'], isFalse);
    });

    test('status filter affects total count', () {
      seedTasks(20, status: 'todo');
      seedTasks(10, status: 'done');

      final data = parseResult(taskOps.listTasks({'status': 'done'}));
      expect(data['total'], 10);
      expect(data['count'], 10);
      expect(data['has_more'], isFalse);
    });

    test('custom limit is respected', () {
      seedTasks(15);

      final data = parseResult(taskOps.listTasks({'limit': 5}));
      expect(data['count'], 5);
      expect(data['total'], 15);
      expect(data['limit'], 5);
      expect(data['has_more'], isTrue);
    });
  });

  group('list-items pagination', () {
    test('paging with limit and start_at returns correct slice', () {
      seedItems(40);

      final data = parseResult(itemOps.listItems({'limit': 10, 'start_at': 20}));
      expect(data['count'], 10);
      expect(data['total'], 40);
      expect(data['start_at'], 20);
      expect(data['limit'], 10);
      expect(data['has_more'], isTrue);
    });

    test('last page has has_more=false', () {
      seedItems(25);

      final data = parseResult(itemOps.listItems({'start_at': 20, 'limit': 10}));
      expect(data['count'], 5);
      expect(data['total'], 25);
      expect(data['has_more'], isFalse);
    });
  });

  group('list-slates pagination', () {
    test('single page returns all slates with correct metadata', () {
      seedSlates(5);

      final data = parseResult(slateOps.listSlates({}));
      expect(data['count'], 5);
      expect(data['total'], 5);
      expect(data['start_at'], 0);
      expect(data['limit'], 30);
      expect(data['has_more'], isFalse);
    });

    test('paging works with more slates than limit', () {
      seedSlates(10);

      final data = parseResult(slateOps.listSlates({'limit': 3}));
      expect(data['count'], 3);
      expect(data['total'], 10);
      expect(data['has_more'], isTrue);
    });
  });

  group('pagination validation errors', () {
    test('limit=0 returns validation error', () {
      final text = resultText(taskOps.listTasks({'limit': 0}));
      expect(text, contains('Error:'));
      expect(text, contains('limit'));
    });

    test('limit=150 returns validation error', () {
      final text = resultText(itemOps.listItems({'limit': 150}));
      expect(text, contains('Error:'));
      expect(text, contains('limit'));
    });

    test('start_at=-1 returns validation error', () {
      final text = resultText(slateOps.listSlates({'start_at': -1}));
      expect(text, contains('Error:'));
      expect(text, contains('start_at'));
    });

    test('limit=101 returns validation error', () {
      final text = resultText(taskOps.listTasks({'limit': 101}));
      expect(text, contains('Error:'));
      expect(text, contains('limit'));
    });
  });
}
