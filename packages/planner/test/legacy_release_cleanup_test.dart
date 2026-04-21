import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:planner_mcp/planner_mcp.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Regression tests for legacy 'releases' table cleanup.
///
/// Verifies that databases originally created by planner_app (with 'releases'
/// tables) are correctly migrated when opened by the MCP server.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('planner_legacy_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Map<String, dynamic> parseResult(CallToolResult result) {
    final text = (result.content.first as TextContent).text;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// Create a DB with legacy 'releases' schema (simulating planner_app).
  /// Does NOT create schema_metadata — simulating MCP opening a planner_app DB
  /// for the first time.
  Database _createLegacyDb(String dbPath) {
    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA foreign_keys=ON');

    // Legacy tables as planner_app would create them
    db.execute('''
      CREATE TABLE releases (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        title TEXT NOT NULL,
        notes TEXT,
        status TEXT NOT NULL DEFAULT 'draft',
        release_date TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    db.execute('''
      CREATE TABLE release_items (
        release_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        added_at TEXT NOT NULL,
        PRIMARY KEY (release_id, item_id),
        FOREIGN KEY (release_id) REFERENCES releases(id) ON DELETE CASCADE
      )
    ''');

    db.execute('''
      CREATE TABLE release_history (
        id TEXT PRIMARY KEY,
        release_id TEXT NOT NULL,
        field_name TEXT NOT NULL,
        old_value TEXT,
        new_value TEXT,
        changed_at TEXT NOT NULL,
        FOREIGN KEY (release_id) REFERENCES releases(id) ON DELETE CASCADE
      )
    ''');

    db.execute(
        'CREATE INDEX idx_releases_project_id ON releases(project_id)');
    db.execute('CREATE INDEX idx_releases_status ON releases(status)');

    // A stray trigger that references 'releases' in its body
    db.execute('''
      CREATE TRIGGER t_bump_release AFTER UPDATE ON releases
      BEGIN
        SELECT 1;
      END
    ''');

    // A stray view over releases
    db.execute(
        'CREATE VIEW v_releases AS SELECT id, title, status FROM releases');

    return db;
  }

  group('Legacy release schema cleanup', () {
    test('renames releases tables to slates when no slates tables exist', () {
      final dbPath = p.join(tempDir.path, 'test_rename.db');
      final legacyDb = _createLegacyDb(dbPath);

      // Seed a release row
      final now = DateTime.now().toUtc().toIso8601String();
      legacyDb.execute('''
        INSERT INTO releases (id, project_id, title, status, created_at, updated_at)
        VALUES ('r1', 'proj1', 'Sprint 1', 'draft', ?, ?)
      ''', [now, now]);
      legacyDb.dispose();

      // Open with initializeDatabase — should clean up legacy tables
      final db = initializeDatabase(dbPath);

      // Verify no legacy objects remain
      final legacyObjects = db.select(
          "SELECT name FROM sqlite_master WHERE sql IS NOT NULL AND (LOWER(sql) LIKE '%releases%' OR name LIKE '%release%')");
      expect(legacyObjects, isEmpty,
          reason: 'All legacy release objects should be cleaned up');

      // Verify slates table exists with the data
      final slates = db.select('SELECT * FROM slates');
      expect(slates, hasLength(1));
      expect(slates.first['id'], 'r1');
      expect(slates.first['title'], 'Sprint 1');

      // Verify column was renamed
      final cols = db.select("PRAGMA table_info(slates)");
      final colNames = cols.map((row) => row['name'] as String).toSet();
      expect(colNames, contains('slate_date'));
      expect(colNames, isNot(contains('release_date')));

      db.dispose();
    });

    test('drops releases when both releases and slates exist (slates has data)',
        () {
      final dbPath = p.join(tempDir.path, 'test_both.db');
      final legacyDb = _createLegacyDb(dbPath);

      final now = DateTime.now().toUtc().toIso8601String();
      // Seed release row (legacy)
      legacyDb.execute('''
        INSERT INTO releases (id, project_id, title, status, created_at, updated_at)
        VALUES ('r1', 'proj1', 'Old Sprint', 'draft', ?, ?)
      ''', [now, now]);

      // Also create slates table with data (simulating MCP fresh-db path)
      legacyDb.execute('''
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
      legacyDb.execute('''
        INSERT INTO slates (id, project_id, title, status, created_at, updated_at)
        VALUES ('s1', 'proj1', 'New Sprint', 'todo', ?, ?)
      ''', [now, now]);
      legacyDb.dispose();

      final db = initializeDatabase(dbPath);

      // releases should be gone, slates should have the new data
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((r) => r['name'] as String)
          .toSet();
      expect(tables, isNot(contains('releases')));
      expect(tables, contains('slates'));

      final slates = db.select('SELECT * FROM slates');
      expect(slates, hasLength(1));
      expect(slates.first['title'], 'New Sprint');

      db.dispose();
    });

    test('keeps releases data when slates is empty', () {
      final dbPath = p.join(tempDir.path, 'test_keep_releases.db');
      final legacyDb = _createLegacyDb(dbPath);

      final now = DateTime.now().toUtc().toIso8601String();
      legacyDb.execute('''
        INSERT INTO releases (id, project_id, title, status, created_at, updated_at)
        VALUES ('r1', 'proj1', 'Old Sprint', 'draft', ?, ?)
      ''', [now, now]);

      // Create empty slates table
      legacyDb.execute('''
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
      legacyDb.dispose();

      final db = initializeDatabase(dbPath);

      final slates = db.select('SELECT * FROM slates');
      expect(slates, hasLength(1));
      expect(slates.first['title'], 'Old Sprint');

      db.dispose();
    });

    test('updateSlate succeeds after legacy cleanup', () {
      final dbPath = p.join(tempDir.path, 'test_update.db');
      final legacyDb = _createLegacyDb(dbPath);

      final now = DateTime.now().toUtc().toIso8601String();
      legacyDb.execute('''
        INSERT INTO releases (id, project_id, title, status, created_at, updated_at)
        VALUES ('r1', 'proj1', 'Sprint 1', 'draft', ?, ?)
      ''', [now, now]);
      legacyDb.dispose();

      // Open with full initialization
      final db = initializeDatabase(dbPath);
      final txRepo = TransactionLogRepository(db);
      txRepo.initializeTable();
      final slateOps = SlateOperations(
        database: db,
        transactionLogRepository: txRepo,
      );

      // This should NOT throw "no such table: main.releases"
      final result = slateOps.updateSlate({'id': 'r1', 'status': 'todo'});
      final data = parseResult(result);
      expect(data['status'], 'todo');

      // Verify in DB
      final row =
          db.select('SELECT status FROM slates WHERE id = ?', ['r1']);
      expect(row.first['status'], 'todo');

      db.dispose();
    });

    test('drops triggers and views referencing releases', () {
      final dbPath = p.join(tempDir.path, 'test_triggers.db');
      final legacyDb = _createLegacyDb(dbPath);
      legacyDb.dispose();

      final db = initializeDatabase(dbPath);

      final triggers = db.select(
          "SELECT name FROM sqlite_master WHERE type='trigger'");
      final triggerNames =
          triggers.map((r) => r['name'] as String).toSet();
      expect(triggerNames, isNot(contains('t_bump_release')));

      final views = db
          .select("SELECT name FROM sqlite_master WHERE type='view'");
      final viewNames = views.map((r) => r['name'] as String).toSet();
      expect(viewNames, isNot(contains('v_releases')));

      db.dispose();
    });
  });
}
