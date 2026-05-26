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
      expect(tableNames, contains('annotations'));
      expect(tableNames, contains('external_symbol_usages'));
    });

    test('creates FTS table with external_symbols column', () {
      final result = database.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='code_search_fts'");
      expect(result, hasLength(1));
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
      searchOps = SearchOperations(database: database, workingDir: workingDir);

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

    test('returns rich results with file metadata', () {
      final result = searchOps.search({'query': 'utils'});
      final text = result.content.first.toJson()['text'] as String;

      // Rich results should include name, description, file_type
      expect(text, contains('"name": "utils.dart"'));
      expect(text, contains('"description": "Utility functions"'));
      expect(text, contains('"file_type": "dart"'));
    });

    test('returns exports summary in search results', () {
      final result = searchOps.search({'query': 'utils'});
      final text = result.content.first.toJson()['text'] as String;

      // Should include exports summary
      expect(text, contains('"exports"'));
      expect(text, contains('"helper"'));
      expect(text, contains('"StringUtils"'));
      expect(text, contains('"function"'));
      expect(text, contains('"class"'));
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

  group('FTS5 search', () {
    late IndexOperations indexOps;
    late SearchOperations searchOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      searchOps = SearchOperations(database: database, workingDir: workingDir);

      // Index files with varied descriptions for ranking tests
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'description': 'Application entry point',
        'file_type': 'dart',
        'exports': [
          {'name': 'main', 'kind': 'function'},
        ],
      });

      indexOps.indexFile({
        'path': 'lib/utils.dart',
        'name': 'utils.dart',
        'description': 'Utility functions for string processing',
        'file_type': 'dart',
        'exports': [
          {'name': 'helper', 'kind': 'function'},
          {'name': 'StringUtils', 'kind': 'class'},
        ],
        'variables': [
          {'name': 'defaultLocale'},
        ],
      });

      indexOps.indexFile({
        'path': 'lib/models.dart',
        'name': 'models.dart',
        'description': 'Data models',
        'file_type': 'dart',
        'exports': [
          {'name': 'User', 'kind': 'class'},
          {'name': 'UserUtils', 'kind': 'class'},
        ],
      });
    });

    test('finds files via FTS query', () {
      final result = searchOps.search({'query': 'utils'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/utils.dart'));
    });

    test('FTS search finds by export names', () {
      final result = searchOps.search({'query': 'StringUtils'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/utils.dart'));
    });

    test('FTS search finds by variable names', () {
      final result = searchOps.search({'query': 'defaultLocale'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/utils.dart'));
    });

    test('FTS search finds by description words', () {
      final result = searchOps.search({'query': 'entry'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/main.dart'));
    });

    test('FTS search finds by file path', () {
      final result = searchOps.search({'query': 'models'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/models.dart'));
    });

    test('FTS search returns no results for unmatched query', () {
      final result = searchOps.search({'query': 'zzzznonexistent'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 0'));
    });

    test('FTS syncs on file update', () {
      // Update utils.dart with new export
      indexOps.indexFile({
        'path': 'lib/utils.dart',
        'name': 'utils.dart',
        'description': 'Utility functions for string processing',
        'file_type': 'dart',
        'exports': [
          {'name': 'helper', 'kind': 'function'},
          {'name': 'StringUtils', 'kind': 'class'},
          {'name': 'DateUtils', 'kind': 'class'},
        ],
      });

      // Should find by new export name
      final result = searchOps.search({'query': 'DateUtils'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/utils.dart'));
    });

    test('FTS can combine with filter parameters', () {
      final result = searchOps.search({
        'query': 'utils',
        'file_type': 'dart',
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/utils.dart'));
    });
  });

  group('GetFile operation', () {
    late IndexOperations indexOps;
    late BrowseOperations browseOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      browseOps = BrowseOperations(database: database, workingDir: workingDir);


      // Index a file with full metadata
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'description': 'Application entry point',
        'file_type': 'dart',
        'exports': [
          {
            'name': 'main',
            'kind': 'function',
            'parameters': 'List<String> args',
            'description': 'Entry point',
          },
          {
            'name': 'App',
            'kind': 'class',
            'description': 'Main application class',
          },
          {
            'name': 'run',
            'kind': 'method',
            'parent_name': 'App',
            'description': 'Run the app',
          },
        ],
        'variables': [
          {'name': 'appVersion', 'description': 'App version string'},
          {'name': 'debug', 'description': 'Debug mode flag'},
        ],
        'imports': ['dart:io', 'package:path/path.dart'],
      });
    });

    test('returns full file metadata', () {
      final result = browseOps.getFile({'path': 'lib/main.dart', 'layers': [0, 1, 2, 3]});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"path": "lib/main.dart"'));
      expect(text, contains('"name": "main.dart"'));
      expect(text, contains('"file_type": "dart"'));
      expect(text, contains('"file_hash"'));
      expect(text, contains('"needs_reindex"'));
    });

    test('returns all exports with full details', () {
      final result = browseOps.getFile({'path': 'lib/main.dart', 'layers': [0, 1, 2, 3]});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"main"'));
      expect(text, contains('"function"'));
      expect(text, contains('"App"'));
      expect(text, contains('"class"'));
      expect(text, contains('"run"'));
      expect(text, contains('"method"'));
    });

    test('returns all variables', () {
      final result = browseOps.getFile({'path': 'lib/main.dart', 'layers': [0, 2]});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"appVersion"'));
      expect(text, contains('"debug"'));
    });

    test('returns all imports', () {
      final result = browseOps.getFile({'path': 'lib/main.dart', 'layers': [0, 2]});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('dart:io'));
      expect(text, contains('package:path/path.dart'));
    });

    test('returns not found for unindexed file', () {
      final result = browseOps.getFile({'path': 'lib/nonexistent.dart'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('not found'));
      expect(text, contains('lib/nonexistent.dart'));
      expect(text, contains('"needs_reindex"'));
    });

    test('returns error when path is missing', () {
      final result = browseOps.getFile({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('path is required'));
    });
  });

  group('Dependency operations', () {
    late IndexOperations indexOps;
    late SearchOperations searchOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      searchOps = SearchOperations(database: database, workingDir: workingDir);

      // Index files with import relationships
      // main.dart imports utils.dart and models.dart
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'description': 'Application entry point',
        'file_type': 'dart',
        'exports': [
          {'name': 'main', 'kind': 'function'},
        ],
        'imports': ['lib/utils.dart', 'lib/models.dart', 'dart:io'],
      });

      // utils.dart imports models.dart
      indexOps.indexFile({
        'path': 'lib/utils.dart',
        'name': 'utils.dart',
        'description': 'Utility functions',
        'file_type': 'dart',
        'exports': [
          {'name': 'helper', 'kind': 'function'},
          {'name': 'StringUtils', 'kind': 'class'},
        ],
        'imports': ['lib/models.dart', 'package:path/path.dart'],
      });

      // models.dart has no imports
      indexOps.indexFile({
        'path': 'lib/models.dart',
        'name': 'models.dart',
        'description': 'Data models',
        'file_type': 'dart',
        'exports': [
          {'name': 'User', 'kind': 'class'},
        ],
      });
    });

    test('dependents finds files that import a path', () {
      final result = searchOps.dependents({'path': 'models.dart'});
      final text = result.content.first.toJson()['text'] as String;

      // Both main.dart and utils.dart import models.dart
      expect(text, contains('lib/main.dart'));
      expect(text, contains('lib/utils.dart'));
      expect(text, contains('"count": 2'));
    });

    test('dependents returns matching imports', () {
      final result = searchOps.dependents({'path': 'utils.dart'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('lib/main.dart'));
      expect(text, contains('"matching_imports"'));
      expect(text, contains('lib/utils.dart'));
    });

    test('dependents includes exports summary', () {
      final result = searchOps.dependents({'path': 'models.dart'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"exports"'));
    });

    test('dependents returns empty for file with no dependents', () {
      final result = searchOps.dependents({'path': 'main.dart'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 0'));
    });

    test('dependents returns error when path is missing', () {
      final result = searchOps.dependents({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('path is required'));
    });

    test('dependencies returns all imports for a file', () {
      final result = searchOps.dependencies({'path': 'lib/main.dart'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 3'));
      expect(text, contains('lib/utils.dart'));
      expect(text, contains('lib/models.dart'));
      expect(text, contains('dart:io'));
    });

    test('dependencies classifies internal vs external imports', () {
      final result = searchOps.dependencies({'path': 'lib/main.dart'});
      final text = result.content.first.toJson()['text'] as String;

      // utils.dart and models.dart are indexed (internal)
      expect(text, contains('"internal_count": 2'));
      // dart:io is not indexed (external)
      expect(text, contains('"external_count": 1'));
    });

    test('dependencies includes metadata for indexed imports', () {
      final result = searchOps.dependencies({'path': 'lib/utils.dart'});
      final text = result.content.first.toJson()['text'] as String;

      // models.dart is indexed, should have resolved info
      expect(text, contains('"is_indexed": true'));
      expect(text, contains('"resolved_path"'));
      expect(text, contains('"Data models"'));
    });

    test('dependencies returns empty for file with no imports', () {
      final result = searchOps.dependencies({'path': 'lib/models.dart'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 0'));
    });

    test('dependencies returns not found for unindexed file', () {
      final result = searchOps.dependencies({'path': 'lib/nonexistent.dart'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('not found'));
    });

    test('dependencies returns error when path is missing', () {
      final result = searchOps.dependencies({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('path is required'));
    });
  });

  group('Annotation tracking', () {
    late IndexOperations indexOps;
    late SearchOperations searchOps;
    late BrowseOperations browseOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      searchOps = SearchOperations(database: database, workingDir: workingDir);
      browseOps = BrowseOperations(database: database, workingDir: workingDir);


      // Index files with annotations
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'description': 'Application entry point',
        'file_type': 'dart',
        'exports': [
          {'name': 'main', 'kind': 'function'},
        ],
        'annotations': [
          {'kind': 'TODO', 'message': 'Add error handling', 'line': 10},
          {'kind': 'FIXME', 'message': 'Memory leak in loop', 'line': 25},
        ],
      });

      indexOps.indexFile({
        'path': 'lib/utils.dart',
        'name': 'utils.dart',
        'description': 'Utility functions',
        'file_type': 'dart',
        'annotations': [
          {'kind': 'TODO', 'message': 'Optimize string parsing', 'line': 5},
          {'kind': 'HACK', 'message': 'Workaround for platform bug', 'line': 42},
        ],
      });

      indexOps.indexFile({
        'path': 'pubspec.yaml',
        'name': 'pubspec.yaml',
        'description': 'Package configuration',
        'file_type': 'yaml',
      });
    });

    test('index-file stores annotations and reports count', () {
      final result = indexOps.indexFile({
        'path': 'lib/models.dart',
        'name': 'models.dart',
        'file_type': 'dart',
        'annotations': [
          {'kind': 'TODO', 'message': 'Add validation', 'line': 3},
        ],
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"annotation_count": 1'));
    });

    test('index-file with no annotations reports zero count', () {
      final result = indexOps.indexFile({
        'path': 'lib/models.dart',
        'name': 'models.dart',
        'file_type': 'dart',
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"annotation_count": 0'));
    });

    test('getFile returns needs_reindex for indexed file with annotations', () {
      final result = browseOps.getFile({'path': 'lib/main.dart', 'layers': [0, 1, 2]});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"needs_reindex"'));
      expect(text, contains('"exports"'));
    });

    test('search-annotations returns all annotations', () {
      final result = searchOps.searchAnnotations({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 4'));
      expect(text, contains('"by_kind"'));
    });

    test('search-annotations filters by kind', () {
      final result = searchOps.searchAnnotations({'kind': 'TODO'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 2'));
      expect(text, contains('"Add error handling"'));
      expect(text, contains('"Optimize string parsing"'));
      expect(text, isNot(contains('"FIXME"')));
      expect(text, isNot(contains('"HACK"')));
    });

    test('search-annotations filters by message_pattern', () {
      final result =
          searchOps.searchAnnotations({'message_pattern': 'leak'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 1'));
      expect(text, contains('"Memory leak in loop"'));
    });

    test('search-annotations filters by path_pattern', () {
      final result =
          searchOps.searchAnnotations({'path_pattern': 'utils'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 2'));
      expect(text, contains('lib/utils.dart'));
      expect(text, isNot(contains('lib/main.dart')));
    });

    test('search-annotations filters by file_type', () {
      final result =
          searchOps.searchAnnotations({'file_type': 'dart'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 4'));
    });

    test('search-annotations returns by_kind summary', () {
      final result = searchOps.searchAnnotations({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"TODO": 2'));
      expect(text, contains('"FIXME": 1'));
      expect(text, contains('"HACK": 1'));
    });

    test('annotations are cleaned up on file re-index', () {
      // Verify initial state
      final before = searchOps.searchAnnotations({'kind': 'TODO'});
      final beforeText = before.content.first.toJson()['text'] as String;
      expect(beforeText, contains('"count": 2'));

      // Re-index main.dart with different annotations
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'description': 'Application entry point',
        'file_type': 'dart',
        'annotations': [
          {'kind': 'NOTE', 'message': 'Refactored', 'line': 1},
        ],
      });

      // Old annotations should be gone, new one present
      final after = searchOps.searchAnnotations({});
      final afterText = after.content.first.toJson()['text'] as String;

      // Should now have 3: 1 NOTE (main.dart) + 1 TODO + 1 HACK (utils.dart)
      expect(afterText, contains('"count": 3'));
      expect(afterText, contains('"NOTE"'));
      expect(afterText, isNot(contains('"Add error handling"')));
      expect(afterText, isNot(contains('"FIXME"')));
    });

    test('annotations are removed when file is deleted', () {
      // Delete the file from disk
      File(p.join(tempDir.path, 'lib', 'main.dart')).deleteSync();

      // Use diff to remove deleted files
      final diffOps =
          DiffOperations(database: database, workingDir: workingDir);
      diffOps.diff({
        'directories': ['lib'],
        'file_extensions': ['.dart'],
        'remove_deleted': true,
      });

      // Annotations for deleted file should be gone (CASCADE)
      final result = searchOps.searchAnnotations({});
      final text = result.content.first.toJson()['text'] as String;

      // Only utils.dart annotations should remain
      expect(text, contains('"count": 2'));
      expect(text, isNot(contains('"Add error handling"')));
      expect(text, isNot(contains('"FIXME"')));
    });
  });

  group('Stats operation', () {
    late IndexOperations indexOps;
    late SearchOperations searchOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      searchOps = SearchOperations(database: database, workingDir: workingDir);

      // Index files with varied metadata
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'description': 'Application entry point',
        'file_type': 'dart',
        'exports': [
          {'name': 'main', 'kind': 'function'},
          {'name': 'App', 'kind': 'class'},
        ],
        'variables': [
          {'name': 'appVersion'},
        ],
        'imports': ['dart:io', 'lib/utils.dart'],
        'annotations': [
          {'kind': 'TODO', 'message': 'Add error handling', 'line': 10},
        ],
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
        'imports': ['dart:io', 'lib/models.dart'],
        'annotations': [
          {'kind': 'TODO', 'message': 'Optimize parsing', 'line': 5},
          {'kind': 'FIXME', 'message': 'Memory leak', 'line': 20},
        ],
      });

      indexOps.indexFile({
        'path': 'lib/models.dart',
        'name': 'models.dart',
        'description': 'Data models',
        'file_type': 'dart',
        'exports': [
          {'name': 'User', 'kind': 'class'},
        ],
      });

      indexOps.indexFile({
        'path': 'pubspec.yaml',
        'name': 'pubspec.yaml',
        'description': 'Package configuration',
        'file_type': 'yaml',
      });
    });

    test('returns file counts and breakdown by type', () {
      final result = searchOps.stats({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"total": 4'));
      expect(text, contains('"dart": 3'));
      expect(text, contains('"yaml": 1'));
    });

    test('returns export counts and breakdown by kind', () {
      final result = searchOps.stats({});
      final text = result.content.first.toJson()['text'] as String;

      // 5 exports: 2 functions, 3 classes
      expect(text, contains('"exports"'));
      expect(text, contains('"function": 2'));
      expect(text, contains('"class": 3'));
    });

    test('returns variable count', () {
      final result = searchOps.stats({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"variables"'));
    });

    test('returns import counts and top imported paths', () {
      final result = searchOps.stats({});
      final text = result.content.first.toJson()['text'] as String;

      // 4 imports total: dart:io (2x), lib/utils.dart (1x), lib/models.dart (1x)
      expect(text, contains('"top_imported"'));
      expect(text, contains('dart:io'));
      // dart:io should be first (highest count)
      expect(text, contains('"count": 2'));
    });

    test('returns annotation counts and breakdown by kind', () {
      final result = searchOps.stats({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"annotations"'));
      expect(text, contains('"TODO": 2'));
      expect(text, contains('"FIXME": 1'));
    });

    test('returns zero counts for empty index', () {
      // Use a fresh database
      final freshDb = initializeDatabase(':memory:');
      final freshSearchOps = SearchOperations(database: freshDb, workingDir: workingDir);

      final result = freshSearchOps.stats({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"total": 0'));
      closeDatabase(freshDb);
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

    test('defaults to project root when directories omitted', () {
      final result = diffOps.diff({});
      final text = result.content.first.toJson()['text'] as String;

      // Should scan from root and find all files (lib/*.dart + pubspec.yaml)
      expect(text, contains('"total_scanned"'));
      // Should detect the unindexed files as added
      expect(text, contains('"added"'));
    });

    test('returns error for empty directories list', () {
      final result = diffOps.diff({'directories': []});
      expect(result.content.first.toJson()['text'],
          contains('directories must not be empty'));
    });
  });
  group('Overview operation', () {
    late IndexOperations indexOps;
    late BrowseOperations browseOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      browseOps = BrowseOperations(database: database, workingDir: workingDir);


      // Index test files with varied metadata
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'description': 'Application entry point',
        'file_type': 'dart',
        'exports': [
          {'name': 'main', 'kind': 'function'},
          {'name': 'App', 'kind': 'class'},
        ],
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

    test('returns all indexed files with descriptions and exports', () {
      final result = browseOps.overview({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 3'));
      expect(text, contains('lib/main.dart'));
      expect(text, contains('lib/utils.dart'));
      expect(text, contains('pubspec.yaml'));
      expect(text, contains('"Application entry point"'));
      expect(text, contains('"Utility functions"'));
    });

    test('exports are formatted as "name (kind)" strings', () {
      final result = browseOps.overview({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('App (class)'));
      expect(text, contains('main (function)'));
      expect(text, contains('StringUtils (class)'));
      expect(text, contains('helper (function)'));
    });

    test('files are sorted by path', () {
      final result = browseOps.overview({});
      final text = result.content.first.toJson()['text'] as String;

      // lib/main.dart should appear before lib/utils.dart before pubspec.yaml
      final mainIdx = text.indexOf('lib/main.dart');
      final utilsIdx = text.indexOf('lib/utils.dart');
      final pubspecIdx = text.indexOf('pubspec.yaml');
      expect(mainIdx, lessThan(utilsIdx));
      expect(utilsIdx, lessThan(pubspecIdx));
    });

    test('filters by path_pattern', () {
      final result = browseOps.overview({'path_pattern': 'lib/'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 2'));
      expect(text, contains('lib/main.dart'));
      expect(text, contains('lib/utils.dart'));
      expect(text, isNot(contains('pubspec.yaml')));
    });

    test('filters by file_type', () {
      final result = browseOps.overview({'file_type': 'yaml'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 1'));
      expect(text, contains('pubspec.yaml'));
      expect(text, isNot(contains('main.dart')));
    });

    test('returns empty for empty index', () {
      final freshDb = initializeDatabase(':memory:');
      final freshBrowseOps = BrowseOperations(database: freshDb, workingDir: workingDir);

      final result = freshBrowseOps.overview({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 0'));
      closeDatabase(freshDb);
    });
  });

  group('GetFile with public API layer (layer 4)', () {
    late IndexOperations indexOps;
    late BrowseOperations browseOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      browseOps = BrowseOperations(database: database, workingDir: workingDir);

      // Index a file with classes, methods, variables, imports, and annotations
      indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'description': 'Application entry point',
        'file_type': 'dart',
        'exports': [
          {
            'name': 'main',
            'kind': 'function',
            'parameters': 'List<String> args',
            'description': 'Entry point',
          },
          {
            'name': 'App',
            'kind': 'class',
            'description': 'Main application class',
          },
          {
            'name': 'run',
            'kind': 'method',
            'parent_name': 'App',
            'parameters': '()',
            'description': 'Run the app',
          },
          {
            'name': 'stop',
            'kind': 'method',
            'parent_name': 'App',
            'description': 'Stop the app',
          },
        ],
        'variables': [
          {'name': 'appVersion', 'description': 'App version string'},
          {'name': 'debug', 'description': 'Debug mode flag'},
        ],
        'imports': ['dart:io', 'package:path/path.dart'],
        'annotations': [
          {'kind': 'TODO', 'message': 'Add error handling', 'line': 10},
        ],
      });
    });

    test('returns public exports (layer 4 filters private symbols)', () {
      final result = browseOps.getFile({'path': 'lib/main.dart', 'layers': [0, 1, 4]});
      final text = result.content.first.toJson()['text'] as String;

      // Public exports should be present
      expect(text, contains('"main"'));
      expect(text, contains('"function"'));
      expect(text, contains('"App"'));
      expect(text, contains('"run"'));
      expect(text, contains('"stop"'));
      expect(text, contains('"method"'));
    });

    test('returns variables with layer 4', () {
      final result = browseOps.getFile({'path': 'lib/main.dart', 'layers': [0, 4]});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"appVersion"'));
      expect(text, contains('"debug"'));
    });

    test('returns not found for unindexed file', () {
      final result = browseOps.getFile({'path': 'lib/nonexistent.dart'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('not found'));
      expect(text, contains('lib/nonexistent.dart'));
    });

    test('returns error when path is missing', () {
      final result = browseOps.getFile({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('path is required'));
    });
  });

  group('IndexOperations with allowed paths', () {
    late IndexOperations indexOps;

    setUp(() {
      indexOps = IndexOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [p.join(tempDir.path, 'lib')],
      );
    });

    test('rejects indexing a file outside allowed paths', () {
      final result = indexOps.indexFile({
        'path': 'pubspec.yaml',
        'name': 'pubspec.yaml',
        'file_type': 'yaml',
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('outside allowed paths'));
      expect(text, contains('pubspec.yaml'));
    });

    test('allows indexing a file within allowed paths', () {
      final result = indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'file_type': 'dart',
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"success": true'));
    });

    test('allows all paths when allowedPaths is empty', () {
      final unrestrictedOps = IndexOperations(
        database: database,
        workingDir: workingDir,
      );
      final result = unrestrictedOps.indexFile({
        'path': 'pubspec.yaml',
        'name': 'pubspec.yaml',
        'file_type': 'yaml',
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"success": true'));
    });
  });

  group('DiffOperations with allowed paths', () {
    late IndexOperations indexOps;

    setUp(() {
      // Use unrestricted indexOps for setup
      indexOps = IndexOperations(database: database, workingDir: workingDir);

      // Index lib files
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

    test('diff only scans files within allowed paths', () {
      final diffOps = DiffOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [p.join(tempDir.path, 'lib')],
      );

      final result = diffOps.diff({
        'directories': ['.'],
      });
      final text = result.content.first.toJson()['text'] as String;

      // pubspec.yaml should not appear in the added list (outside allowed paths)
      // It may appear in an out_of_scope section, which is fine.
      expect(text, contains('"added_count": 3'));

      // lib/models.dart should appear as added (inside allowed paths, not indexed)
      expect(text, contains('lib/models.dart'));
    });

    test('diff with empty allowedPaths scans all files', () {
      final diffOps = DiffOperations(
        database: database,
        workingDir: workingDir,
      );

      final result = diffOps.diff({
        'directories': ['.'],
      });
      final text = result.content.first.toJson()['text'] as String;

      // pubspec.yaml should appear (no restrictions)
      expect(text, contains('pubspec.yaml'));
    });
  });

  group('Auto-index operation', () {
    late IndexOperations indexOps;
    late SearchOperations searchOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      searchOps = SearchOperations(database: database, workingDir: workingDir);

      // Create a Dart file with rich content for auto-indexing
      File(p.join(tempDir.path, 'lib', 'sample.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'dart:io';
import 'package:path/path.dart';

/// A sample class for testing.
class SampleService {
  final String name;

  SampleService(this.name);

  /// Processes the input data.
  String process(String input) {
    return input.toUpperCase();
  }

  /// Gets the status.
  bool get isActive => true;
}

/// Top-level helper function.
void runService(SampleService service) {
  service.process('test');
}

// TODO: Add error handling here
const appVersion = '1.0.0';
final debugMode = false;

enum Status { active, inactive, pending }
''');

      // Create a non-Dart file
      File(p.join(tempDir.path, 'lib', 'config.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('name: test_project\nversion: 1.0.0');
    });

    test('auto-indexes a Dart file with full metadata', () async {
      final result = await indexOps.autoIndex({
        'path': 'lib/sample.dart',
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"success": true'));
      expect(text, contains('"name": "sample.dart"'));

      // Verify file was indexed in the database
      final files = database.select(
          "SELECT * FROM files WHERE path = 'lib/sample.dart'");
      expect(files.length, 1);
      expect(files.first['name'], 'sample.dart');
      expect(files.first['file_type'], 'dart');

      // Verify layer 0 fields
      expect(files.first['size_bytes'], isNotNull);
      expect(files.first['line_count'], isNotNull);
      expect(files.first['word_count'], isNotNull);
      expect(files.first['mtime'], isNotNull);
      expect(files.first['file_hash'], isNotEmpty);
      expect(files.first['analysis_status'], 'fresh');
      expect(files.first['last_analyzed_at'], isNotNull);
      expect(files.first['layers_present'], isNotNull);

      // Verify exports were extracted
      final fileId = files.first['id'] as String;
      final exports = database.select(
          'SELECT * FROM exports WHERE file_id = ? ORDER BY name', [fileId]);

      final exportNames = exports.map((e) => e['name'] as String).toList();
      expect(exportNames, contains('SampleService'));
      expect(exportNames, contains('Status'));
      expect(exportNames, contains('process'));
      expect(exportNames, contains('runService'));
      expect(exportNames, contains('isActive'));

      // Verify methods have parent_name
      final processExport = exports.firstWhere((e) => e['name'] == 'process');
      expect(processExport['parent_name'], 'SampleService');
      expect(processExport['kind'], 'method');

      // Verify class
      final classExport = exports.firstWhere((e) => e['name'] == 'SampleService' && e['kind'] == 'class');
      expect(classExport['kind'], 'class');

      // Verify enum
      final enumExport = exports.firstWhere((e) => e['name'] == 'Status');
      expect(enumExport['kind'], 'enum');

      // Verify top-level function
      final funcExport = exports.firstWhere((e) => e['name'] == 'runService');
      expect(funcExport['kind'], 'function');
      expect(funcExport['parent_name'], isNull);

      // Verify imports
      final imports = database.select(
          'SELECT * FROM imports WHERE file_id = ?', [fileId]);
      final importPaths = imports.map((i) => i['import_path'] as String).toList();
      expect(importPaths, contains('dart:io'));
      expect(importPaths, contains('package:path/path.dart'));

      // Verify variables
      final variables = database.select(
          'SELECT * FROM variables WHERE file_id = ?', [fileId]);
      final varNames = variables.map((v) => v['name'] as String).toList();
      expect(varNames, contains('appVersion'));
      expect(varNames, contains('debugMode'));

      // Verify annotations
      final annotations = database.select(
          'SELECT * FROM annotations WHERE file_id = ?', [fileId]);
      expect(annotations.length, 1);
      expect(annotations.first['kind'], 'TODO');
      expect(annotations.first['message'], contains('Add error handling'));
    });

    test('auto-indexes with LLM-provided short_summary', () async {
      final result = await indexOps.autoIndex({
        'path': 'lib/sample.dart',
        'short_summary': 'A sample service module for processing data',
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"success": true'));

      // Verify short_summary is stored
      final files = database.select(
          "SELECT * FROM files WHERE path = 'lib/sample.dart'");
      expect(files.first['short_summary'],
          'A sample service module for processing data');
      // description also gets short_summary for backward compat
      expect(files.first['description'],
          'A sample service module for processing data');

      // Verify exports were still extracted
      final fileId = files.first['id'] as String;
      final exports = database.select(
          'SELECT * FROM exports WHERE file_id = ?', [fileId]);
      expect(exports.length, greaterThan(0));
    });

    test('auto-indexes a non-Dart file with manual structural fields', () async {
      final result = await indexOps.autoIndex({
        'path': 'lib/config.yaml',
        'short_summary': 'Project configuration',
        'exports': [
          {'name': 'name', 'kind': 'variable'},
          {'name': 'version', 'kind': 'variable'},
        ],
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"success": true'));
      expect(text, contains('"name": "config.yaml"'));

      // Verify file metadata
      final files = database.select(
          "SELECT * FROM files WHERE path = 'lib/config.yaml'");
      expect(files.length, 1);
      expect(files.first['file_type'], 'yaml');
      expect(files.first['short_summary'], 'Project configuration');
      expect(files.first['analysis_status'], 'fresh');

      // Verify exports from manual structural fields
      final fileId = files.first['id'] as String;
      final exports = database.select(
          'SELECT * FROM exports WHERE file_id = ?', [fileId]);
      expect(exports.length, 2);
    });

    test('auto-indexes non-Dart file with no structural fields', () async {
      final result = await indexOps.autoIndex({
        'path': 'lib/config.yaml',
        'short_summary': 'Project configuration',
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"success": true'));

      // Non-Dart files without manual fields should have no child rows
      final fileId = database.select(
          "SELECT id FROM files WHERE path = 'lib/config.yaml'").first['id'] as String;
      expect(database.select('SELECT * FROM exports WHERE file_id = ?', [fileId]).length, 0);
      expect(database.select('SELECT * FROM imports WHERE file_id = ?', [fileId]).length, 0);
      expect(database.select('SELECT * FROM variables WHERE file_id = ?', [fileId]).length, 0);
      expect(database.select('SELECT * FROM annotations WHERE file_id = ?', [fileId]).length, 0);
    });

    test('returns error for missing path', () async {
      final result = await indexOps.autoIndex({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('path is required'));
    });

    test('returns error for non-existent file', () async {
      final result = await indexOps.autoIndex({
        'path': 'lib/nonexistent.dart',
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('File not found'));
    });

    test('updates existing entry on re-index', () async {
      // First auto-index
      await indexOps.autoIndex({
        'path': 'lib/sample.dart',
        'short_summary': 'Original description',
      });

      // Verify initial state
      final filesBefore = database.select(
          "SELECT * FROM files WHERE path = 'lib/sample.dart'");
      expect(filesBefore.length, 1);
      final originalId = filesBefore.first['id'] as String;

      // Re-index with different short_summary
      final result = await indexOps.autoIndex({
        'path': 'lib/sample.dart',
        'short_summary': 'Updated description',
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"File index updated"'));

      // Should still be one file (upsert, not duplicate)
      final filesAfter = database.select(
          "SELECT * FROM files WHERE path = 'lib/sample.dart'");
      expect(filesAfter.length, 1);
      expect(filesAfter.first['id'], originalId);
      expect(filesAfter.first['short_summary'], 'Updated description');
    });

    test('auto-index respects allowed paths', () async {
      final restrictedOps = IndexOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [p.join(tempDir.path, 'lib')],
      );

      // File inside allowed path should work
      final result = await restrictedOps.autoIndex({
        'path': 'lib/sample.dart',
      });
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"success": true'));

      // File outside allowed path should fail
      final result2 = await restrictedOps.autoIndex({
        'path': 'pubspec.yaml',
      });
      final text2 = result2.content.first.toJson()['text'] as String;
      expect(text2, contains('outside allowed paths'));
    });

    test('auto-indexed file is searchable via FTS', () async {
      await indexOps.autoIndex({
        'path': 'lib/sample.dart',
        'short_summary': 'Sample service module',
      });

      // Search by export name
      final result = searchOps.search({'query': 'SampleService'});
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('lib/sample.dart'));

      // Search by short_summary (written to FTS description column)
      final result2 = searchOps.search({'query': 'Sample service'});
      final text2 = result2.content.first.toJson()['text'] as String;
      expect(text2, contains('lib/sample.dart'));
    });

    test('layer 3 symbol_summaries are applied to exports', () async {
      final result = await indexOps.autoIndex({
        'path': 'lib/sample.dart',
        'symbol_summaries': {
          'SampleService': 'A service that processes samples',
          'runService': 'Runs the given service',
        },
      });
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"success": true'));

      // Verify descriptions were applied
      final fileId = database.select(
          "SELECT id FROM files WHERE path = 'lib/sample.dart'").first['id'] as String;
      final sampleExport = database.select(
          "SELECT description FROM exports WHERE file_id = ? AND name = 'SampleService' AND kind = 'class'",
          [fileId]).first;
      expect(sampleExport['description'], 'A service that processes samples');

      final runExport = database.select(
          "SELECT description FROM exports WHERE file_id = ? AND name = 'runService'",
          [fileId]).first;
      expect(runExport['description'], 'Runs the given service');
    });

    test('layers_present reflects which layers were populated', () async {
      // Only layer 0 and 2 (no short_summary, no symbol_summaries)
      await indexOps.autoIndex({
        'path': 'lib/sample.dart',
        'layers': [0, 2],
      });
      final files = database.select(
          "SELECT layers_present FROM files WHERE path = 'lib/sample.dart'");
      expect(files.first['layers_present'], '[0,2]');
    });
  });

  group('Usages operation', () {
    late SearchOperations searchOps;

    setUp(() {
      searchOps = SearchOperations(database: database, workingDir: workingDir);

      // Create a file and insert external_symbol_usages manually for testing
      final now = DateTime.now().toUtc().toIso8601String();
      database.execute('''
        INSERT INTO files (id, path, name, file_type, file_hash, analysis_status, created_at, updated_at)
        VALUES ('file1', 'lib/main.dart', 'main.dart', 'dart', 'abc123', 'fresh', ?, ?)
      ''', [now, now]);

      database.execute('''
        INSERT INTO external_symbol_usages (id, file_id, module, source_path, symbol, symbol_kind, dot_path, reference_count, created_at, updated_at)
        VALUES ('u1', 'file1', 'path', 'path', 'join', 'function', 'path.path.join', 3, ?, ?)
      ''', [now, now]);

      database.execute('''
        INSERT INTO external_symbol_usages (id, file_id, module, source_path, symbol, symbol_kind, dot_path, reference_count, created_at, updated_at)
        VALUES ('u2', 'file1', 'dart', 'io', 'File', 'class', 'dart.io.File', 5, ?, ?)
      ''', [now, now]);

      // Second file
      database.execute('''
        INSERT INTO files (id, path, name, file_type, file_hash, analysis_status, created_at, updated_at)
        VALUES ('file2', 'lib/utils.dart', 'utils.dart', 'dart', 'def456', 'fresh', ?, ?)
      ''', [now, now]);

      database.execute('''
        INSERT INTO external_symbol_usages (id, file_id, module, source_path, symbol, symbol_kind, dot_path, reference_count, created_at, updated_at)
        VALUES ('u3', 'file2', 'dart', 'io', 'File', 'class', 'dart.io.File', 2, ?, ?)
      ''', [now, now]);
    });

    test('returns all usages when no filters', () {
      final result = searchOps.usages({});
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"count": 3'));
    });

    test('filters by symbol', () {
      final result = searchOps.usages({'symbol': 'File'});
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"count": 2'));
      expect(text, contains('dart.io.File'));
    });

    test('filters by module', () {
      final result = searchOps.usages({'module': 'path'});
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"count": 1'));
      expect(text, contains('path.path.join'));
    });

    test('filters by source_path', () {
      final result = searchOps.usages({'source_path': 'io'});
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"count": 2'));
    });

    test('filters by dot_path_pattern', () {
      final result = searchOps.usages({'dot_path_pattern': 'dart.io'});
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"count": 2'));
    });

    test('filters by kind', () {
      final result = searchOps.usages({'kind': 'function'});
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"count": 1'));
      expect(text, contains('join'));
    });

    test('filters by path_pattern', () {
      final result = searchOps.usages({'path_pattern': 'utils'});
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"count": 1'));
      expect(text, contains('lib/utils.dart'));
    });

    test('returns expected row shape', () {
      final result = searchOps.usages({'symbol': 'join'});
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"path": "lib/main.dart"'));
      expect(text, contains('"dot_path": "path.path.join"'));
      expect(text, contains('"symbol": "join"'));
      expect(text, contains('"module": "path"'));
      expect(text, contains('"source_path": "path"'));
      expect(text, contains('"kind": "function"'));
      expect(text, contains('"reference_count": 3'));
    });

    test('combines multiple filters', () {
      final result = searchOps.usages({
        'symbol': 'File',
        'path_pattern': 'main',
      });
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"count": 1'));
      expect(text, contains('lib/main.dart'));
    });

    test('returns empty for no matches', () {
      final result = searchOps.usages({'symbol': 'NonExistent'});
      final text = result.content.first.toJson()['text'] as String;
      expect(text, contains('"count": 0'));
    });
  });


  group('Stale detection and layer selection', () {
    late IndexOperations indexOps;
    late BrowseOperations browseOps;
    late SearchOperations searchOps;

    setUp(() {
      indexOps = IndexOperations(database: database, workingDir: workingDir);
      browseOps = BrowseOperations(database: database, workingDir: workingDir);
      searchOps = SearchOperations(database: database, workingDir: workingDir);
    });

    test('fresh file returns empty needs_reindex', () async {
      // Index the file with layers that will all be populated
      await indexOps.autoIndex({
        'path': 'lib/main.dart',
        'layers': [0, 1, 2],
        'short_summary': 'Main entry point',
      });

      // Read it back with matching layers — file unchanged on disk
      final result = browseOps.getFile({
        'path': 'lib/main.dart',
        'layers': [0, 1, 2],
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"needs_reindex": []'));
      expect(text, contains('"analysis_status": "fresh"'));
    });


    test('changed file returns needs_reindex with reason changed', () async {
      // Index the file
      await indexOps.autoIndex({
        'path': 'lib/main.dart',
        'layers': [0, 1, 2],
        'short_summary': 'Main entry point',
      });

      // Modify the file on disk
      final file = File(p.join(tempDir.path, 'lib', 'main.dart'));
      file.writeAsStringSync('// changed\nvoid main() {}');

      // Read it back — hash should mismatch
      final result = browseOps.getFile({
        'path': 'lib/main.dart',
        'layers': [0, 1, 2],
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"needs_reindex"'));
      expect(text, contains('"reason": "changed"'));

      // Verify DB was marked stale
      final rows = database.select(
        "SELECT analysis_status FROM files WHERE path = 'lib/main.dart'",
      );
      expect(rows.first['analysis_status'], 'stale');
    });

    test('missing layer returns needs_reindex with reason missing_layer', () async {
      // Index with only layers [0, 1]
      await indexOps.autoIndex({
        'path': 'lib/main.dart',
        'layers': [0, 1],
        'short_summary': 'Main entry point',
      });

      // Request layers [0, 1, 2, 3] — layers 2 and 3 were never populated
      final result = browseOps.getFile({
        'path': 'lib/main.dart',
        'layers': [0, 1, 2, 3],
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"needs_reindex"'));
      expect(text, contains('"reason": "missing_layer"'));
    });

    test('get-files aggregates needs_reindex across files', () async {
      // Index both files
      await indexOps.autoIndex({
        'path': 'lib/main.dart',
        'layers': [0, 1, 2],
        'short_summary': 'Main entry point',
      });
      await indexOps.autoIndex({
        'path': 'lib/utils.dart',
        'layers': [0, 1, 2],
        'short_summary': 'Utility functions',
      });

      // Modify only one file on disk
      final file = File(p.join(tempDir.path, 'lib', 'main.dart'));
      file.writeAsStringSync('// modified\nvoid main() {}');

      // get-files should show one stale, one fresh
      final result = browseOps.getFiles({
        'paths': ['lib/main.dart', 'lib/utils.dart'],
        'layers': [0, 1, 2],
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"count": 2'));
      expect(text, contains('"needs_reindex"'));
      expect(text, contains('"reason": "changed"'));
      expect(text, contains('lib/main.dart'));
    });

    test('overview includes needs_reindex for stale files', () async {
      // Index files
      await indexOps.autoIndex({
        'path': 'lib/main.dart',
        'layers': [0, 1, 2],
        'short_summary': 'Main entry point',
      });
      await indexOps.autoIndex({
        'path': 'lib/utils.dart',
        'layers': [0, 1, 2],
        'short_summary': 'Utility functions',
      });

      // Modify one file
      final file = File(p.join(tempDir.path, 'lib', 'utils.dart'));
      file.writeAsStringSync('// changed\nString helper() => "world";');

      final result = browseOps.overview({});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"needs_reindex"'));
      expect(text, contains('"reason": "changed"'));
      expect(text, contains('lib/utils.dart'));
    });

    test('search includes needs_reindex for stale files', () async {
      await indexOps.autoIndex({
        'path': 'lib/main.dart',
        'layers': [0, 1, 2],
        'short_summary': 'Main entry point',
      });

      // Modify file
      final file = File(p.join(tempDir.path, 'lib', 'main.dart'));
      file.writeAsStringSync('// changed\nvoid main() {}');

      final result = searchOps.search({'path_pattern': 'lib/main.dart'});
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"needs_reindex"'));
      expect(text, contains('"reason": "changed"'));
    });

    test('layer 4 filters private symbols', () async {
      // Create a file with private and public symbols
      final file = File(p.join(tempDir.path, 'lib', 'mixed.dart'));
      file.createSync(recursive: true);
      file.writeAsStringSync('''
class MyClass {}
class _PrivateClass {}
void publicFunc() {}
void _privateFunc() {}
''');

      // Index it — use indexFile for explicit control over exports
      indexOps.indexFile({
        'path': 'lib/mixed.dart',
        'name': 'mixed.dart',
        'file_type': 'dart',
        'exports': [
          {'name': 'MyClass', 'kind': 'class'},
          {'name': '_PrivateClass', 'kind': 'class'},
          {'name': 'publicFunc', 'kind': 'function'},
          {'name': '_privateFunc', 'kind': 'function'},
        ],
        'variables': [
          {'name': 'publicVar'},
          {'name': '_privateVar'},
        ],
      });

      // Update layers_present to include layer 2
      database.execute(
        "UPDATE files SET layers_present = '[0,2]' WHERE path = 'lib/mixed.dart'",
      );

      // Layer 4 (public API) should filter out _ prefixed symbols
      final result = browseOps.getFile({
        'path': 'lib/mixed.dart',
        'layers': [0, 4],
      });
      final text = result.content.first.toJson()['text'] as String;

      expect(text, contains('"MyClass"'));
      expect(text, contains('"publicFunc"'));
      expect(text, contains('"publicVar"'));
      expect(text, isNot(contains('"_PrivateClass"')));
      expect(text, isNot(contains('"_privateFunc"')));
      expect(text, isNot(contains('"_privateVar"')));
    });
  });

}