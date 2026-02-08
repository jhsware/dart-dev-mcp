import 'dart:io';

import 'package:code_index_mcp/code_index_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database database;
  late Directory tempDir;
  late Directory workingDir;

  setUp(() {
    database = initializeDatabase(':memory:');
    tempDir = Directory.systemTemp.createTempSync('code_index_test_');
    workingDir = tempDir;

    // Create test files
    File(p.join(tempDir.path, 'lib', 'main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    File(p.join(tempDir.path, 'lib', 'utils.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('String helper() => "hello";');
    File(p.join(tempDir.path, 'lib', 'models.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('class User { String name; }');
    File(p.join(tempDir.path, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: test_project');
  });

  tearDown(() {
    closeDatabase(database);
    tempDir.deleteSync(recursive: true);
  });

  group('Database initialization', () {
    test('creates all tables', () {
      final tables = database.select(
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
      final tableNames = tables.map((r) => r['name'] as String).toList();

      expect(tableNames, contains('files'));
      expect(tableNames, contains('exports'));
      expect(tableNames, contains('variables'));
      expect(tableNames, contains('imports'));
      expect(tableNames, contains('schema_metadata'));
    });

    test('sets schema version', () {
      final result = database.select(
          "SELECT value FROM schema_metadata WHERE key = 'schema_version'");
      expect(result.first['value'], '1');
    });

    test('enables foreign keys', () {
      final result = database.select('PRAGMA foreign_keys');
      expect(result.first['foreign_keys'], 1);
    });
  });

  group('IndexOperations', () {
    late IndexOperations indexOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
    });

    test('indexes a new file', () {
      final result = indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'description': 'Application entry point',
        'file_type': 'dart',
        'exports': [
          {'name': 'main', 'kind': 'function', 'description': 'Entry point'},
        ],
        'variables': [
          {'name': 'appVersion', 'description': 'App version string'},
        ],
        'imports': ['dart:io', 'package:path/path.dart'],
      });

      expect(result.content.first.toJson()['text'], contains('"success": true'));
      expect(result.content.first.toJson()['text'], contains('"File indexed"'));

      // Verify database records
      final files = database.select('SELECT * FROM files');
      expect(files.length, 1);
      expect(files.first['path'], 'lib/main.dart');
      expect(files.first['name'], 'main.dart');
      expect(files.first['file_hash'], isNotEmpty);

      final exports = database.select('SELECT * FROM exports');
      expect(exports.length, 1);
      expect(exports.first['name'], 'main');

      final variables = database.select('SELECT * FROM variables');
      expect(variables.length, 1);
      expect(variables.first['name'], 'appVersion');

      final imports = database.select('SELECT * FROM imports');
      expect(imports.length, 2);
    });

    test('updates an existing file (upsert)', () {
      // First index
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'file_type': 'dart',
        'exports': [
          {'name': 'main', 'kind': 'function'},
        ],
      });

      // Update with different exports
      final result = indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'file_type': 'dart',
        'exports': [
          {'name': 'main', 'kind': 'function'},
          {'name': 'App', 'kind': 'class'},
        ],
      });

      expect(result.content.first.toJson()['text'],
          contains('"File index updated"'));

      // Should still be one file
      final files = database.select('SELECT * FROM files');
      expect(files.length, 1);

      // But now two exports
      final exports = database.select('SELECT * FROM exports');
      expect(exports.length, 2);
    });

    test('returns error for missing path', () {
      final result = indexOps.indexFile({'name': 'test.dart'});
      expect(result.content.first.toJson()['text'],
          contains('path is required'));
    });

    test('returns error for non-existent file', () {
      final result = indexOps.indexFile({
        'path': 'lib/nonexistent.dart',
        'name': 'nonexistent.dart',
      });
      expect(result.content.first.toJson()['text'],
          contains('File not found'));
    });
  });

  group('SearchOperations', () {
    late IndexOperations indexOps;
    late SearchOperations searchOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      searchOps = SearchOperations(database: database);

      // Index test files
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'description': 'Application entry point',
        'file_type': 'dart',
        'exports': [
          {'name': 'main', 'kind': 'function'},
        ],
        'imports': ['dart:io'],
      });

      indexOps.indexFile({
        'path': 'lib/utils.dart',
        'name': 'utils.dart',
        'description': 'Utility functions',
        'file_type': 'dart',
        'exports': [
          {'name': 'helper', 'kind': 'function'},
          {'name': 'StringUtils', 'kind': 'class'},
        ],
      });

      indexOps.indexFile({
        'path': 'pubspec.yaml',
        'name': 'pubspec.yaml',
        'description': 'Package configuration',
        'file_type': 'yaml',
      });
    });

    test('searches by general query', () {
      final result = searchOps.search({'query': 'utils'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/utils.dart'));
      expect(text, contains('"count": 1'));
    });

    test('filters by file_type', () {
      final result = searchOps.search({'file_type': 'yaml'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('pubspec.yaml'));
      expect(text, isNot(contains('main.dart')));
    });

    test('searches by export_name', () {
      final result = searchOps.search({'export_name': 'StringUtils'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/utils.dart'));
    });

    test('searches by export_kind', () {
      final result = searchOps.search({'export_kind': 'class'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/utils.dart'));
      expect(text, isNot(contains('main.dart')));
    });

    test('searches by path_pattern', () {
      final result = searchOps.search({'path_pattern': 'lib/'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/main.dart'));
      expect(text, contains('lib/utils.dart'));
    });

    test('returns empty for no matches', () {
      final result = searchOps.search({'query': 'nonexistent_xyz'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 0'));
    });

    test('respects limit parameter', () {
      final result = searchOps.search({'file_type': 'dart', 'limit': 1});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 1'));
    });
  });

  group('DiffOperations', () {
    late IndexOperations indexOps;
    late DiffOperations diffOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      diffOps = DiffOperations(database: database, workingDir: workingDir);

      // Index existing files
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'file_type': 'dart',
      });
      indexOps.indexFile({
        'path': 'lib/utils.dart',
        'name': 'utils.dart',
        'file_type': 'dart',
      });
    });

    test('detects unchanged files', () {
      final result = diffOps.diff({
        'directories': ['lib'],
        'file_extensions': ['.dart'],
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"unchanged_count": 2'));
      expect(text, contains('"changed_count": 0'));
      expect(text, contains('"added_count": 1')); // models.dart not indexed
    });

    test('detects changed files', () {
      // Modify a file on disk
      File(p.join(tempDir.path, 'lib', 'main.dart'))
          .writeAsStringSync('void main() { print("changed"); }');

      final result = diffOps.diff({
        'directories': ['lib'],
        'file_extensions': ['.dart'],
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"changed_count": 1'));
      expect(text, contains('lib/main.dart'));
    });

    test('detects added files', () {
      final result = diffOps.diff({
        'directories': ['lib'],
        'file_extensions': ['.dart'],
      });
      final text = result.content.first.toJson()['text'] as String;

      // models.dart is on disk but not indexed
      expect(text, contains('"added_count": 1'));
      expect(text, contains('lib/models.dart'));
    });

    test('detects deleted files', () {
      // Delete a file from disk
      File(p.join(tempDir.path, 'lib', 'utils.dart')).deleteSync();

      final result = diffOps.diff({
        'directories': ['lib'],
        'file_extensions': ['.dart'],
        'remove_deleted': false,
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"deleted_count": 1'));
      expect(text, contains('lib/utils.dart'));

      // File should still be in the index since remove_deleted is false
      final files = database.select(
          "SELECT * FROM files WHERE path = 'lib/utils.dart'");
      expect(files.length, 1);
    });

    test('removes deleted files from index when remove_deleted is true', () {
      File(p.join(tempDir.path, 'lib', 'utils.dart')).deleteSync();

      diffOps.diff({
        'directories': ['lib'],
        'file_extensions': ['.dart'],
        'remove_deleted': true,
      });

      // File should be removed from index
      final files = database.select(
          "SELECT * FROM files WHERE path = 'lib/utils.dart'");
      expect(files.length, 0);
    });

    test('filters by file extensions', () {
      final result = diffOps.diff({
        'directories': ['.'],
        'file_extensions': ['.yaml'],
      });
      final text = result.content.first.toJson()['text'] as String;

      // pubspec.yaml is on disk but not indexed yet for this diff scope
      expect(text, contains('pubspec.yaml'));
      expect(text, isNot(contains('.dart')));
    });

    test('returns error without directories', () {
      final result = diffOps.diff({});
      expect(result.content.first.toJson()['text'],
          contains('directories is required'));
    });
  });
}
