import 'dart:convert';
import 'dart:io';

import 'package:code_index_mcp/code_index_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late Database database;
  late Directory tempDir;
  late Directory workingDir;

  setUp(() {
    database = initializeDatabase(':memory:');
    tempDir = Directory.systemTemp.createTempSync('code_index_allowed_paths_');
    workingDir = tempDir;

    // Create test files in allowed and disallowed directories
    File(p.join(tempDir.path, 'lib', 'main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    File(p.join(tempDir.path, 'lib', 'utils.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('String helper() => "hello";');
    File(p.join(tempDir.path, 'bin', 'tool.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    File(p.join(tempDir.path, 'test', 'test_main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
  });

  tearDown(() {
    closeDatabase(database);
    tempDir.deleteSync(recursive: true);
  });

  /// Helper to decode JSON from a CallToolResult.
  Map<String, dynamic> parseResult(result) {
    final text = result.content.first.toJson()['text'] as String;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  group('outOfScopeResponse shape', () {
    test('matches the documented JSON shape', () {
      final allowedPaths = [p.join(tempDir.path, 'lib')];
      final indexOps = IndexOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: allowedPaths,
      );

      final result = indexOps.indexFile({
        'path': 'bin/tool.dart',
        'name': 'tool.dart',
      });

      final json = parseResult(result);
      expect(json['status'], 'out_of_scope');
      expect(json['path'], 'bin/tool.dart');
      expect(json['allowed_paths'], isList);
      expect(json['allowed_paths'], contains('lib'));
      expect(json['message'], contains('outside allowed paths'));
    });
  });

  group('IndexOperations allowed-paths', () {
    late IndexOperations indexOps;

    setUp(() {
      indexOps = IndexOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [p.join(tempDir.path, 'lib')],
      );
    });

    test('indexFile succeeds for in-scope path', () {
      final result = indexOps.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'file_type': 'dart',
      });

      final json = parseResult(result);
      expect(json['success'], isTrue);
    });

    test('indexFile returns out_of_scope for disallowed path', () {
      final result = indexOps.indexFile({
        'path': 'bin/tool.dart',
        'name': 'tool.dart',
      });

      final json = parseResult(result);
      expect(json['status'], 'out_of_scope');
      expect(json['path'], 'bin/tool.dart');
    });

    test('autoIndex succeeds for in-scope path', () async {
      final result = await indexOps.autoIndex({
        'path': 'lib/main.dart',
      });

      final json = parseResult(result);
      expect(json['success'], isTrue);
    });

    test('autoIndex returns out_of_scope for disallowed path', () async {
      final result = await indexOps.autoIndex({
        'path': 'bin/tool.dart',
      });

      final json = parseResult(result);
      expect(json['status'], 'out_of_scope');
    });
  });

  group('BrowseOperations allowed-paths', () {
    setUp(() {
      // Index files without restrictions first
      final unrestricted = IndexOperations(
        database: database,
        workingDir: workingDir,
      );
      unrestricted.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'file_type': 'dart',
        'exports': [
          {'name': 'main', 'kind': 'function'},
        ],
      });
      unrestricted.indexFile({
        'path': 'bin/tool.dart',
        'name': 'tool.dart',
        'file_type': 'dart',
      });
    });

    test('getFile succeeds for in-scope path', () {
      final browseOps = BrowseOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [p.join(tempDir.path, 'lib')],
      );

      final result = browseOps.getFile({'path': 'lib/main.dart'});
      final json = parseResult(result);
      expect(json.containsKey('path'), isTrue);
      expect(json['path'], 'lib/main.dart');
    });

    test('getFile returns out_of_scope for disallowed path', () {
      final browseOps = BrowseOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [p.join(tempDir.path, 'lib')],
      );

      final result = browseOps.getFile({'path': 'bin/tool.dart'});
      final json = parseResult(result);
      expect(json['status'], 'out_of_scope');
      expect(json['path'], 'bin/tool.dart');
    });

    test('getFiles returns out_of_scope for any disallowed path', () {
      final browseOps = BrowseOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [p.join(tempDir.path, 'lib')],
      );

      final result = browseOps.getFiles({
        'paths': ['lib/main.dart', 'bin/tool.dart'],
      });
      final json = parseResult(result);
      expect(json['status'], 'out_of_scope');
      expect(json['path'], 'bin/tool.dart');
    });

    test('overview checks path_pattern against allowed paths', () {
      final browseOps = BrowseOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [p.join(tempDir.path, 'lib')],
      );

      final result = browseOps.overview({'path_pattern': 'bin/tool.dart'});
      final json = parseResult(result);
      expect(json['status'], 'out_of_scope');
    });
  });

  group('SearchOperations allowed-paths', () {
    late SearchOperations searchOps;

    setUp(() {
      // Index files without restrictions
      final unrestricted = IndexOperations(
        database: database,
        workingDir: workingDir,
      );
      unrestricted.indexFile({
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'file_type': 'dart',
        'imports': ['dart:io'],
        'exports': [
          {'name': 'main', 'kind': 'function'},
        ],
      });
      unrestricted.indexFile({
        'path': 'bin/tool.dart',
        'name': 'tool.dart',
        'file_type': 'dart',
        'imports': ['dart:io'],
      });

      searchOps = SearchOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [p.join(tempDir.path, 'lib')],
      );
    });

    test('dependents returns out_of_scope for disallowed path', () {
      final result = searchOps.dependents({'path': 'bin/tool.dart'});
      final json = parseResult(result);
      expect(json['status'], 'out_of_scope');
    });

    test('dependents succeeds for in-scope path', () {
      final result = searchOps.dependents({'path': 'lib/main.dart'});
      final json = parseResult(result);
      expect(json.containsKey('dependents'), isTrue);
    });

    test('dependencies returns out_of_scope for disallowed path', () {
      final result = searchOps.dependencies({'path': 'bin/tool.dart'});
      final json = parseResult(result);
      expect(json['status'], 'out_of_scope');
    });

    test('dependencies succeeds for in-scope path', () {
      final result = searchOps.dependencies({'path': 'lib/main.dart'});
      final json = parseResult(result);
      expect(json.containsKey('dependencies'), isTrue);
    });

    test('search with disallowed path_pattern returns out_of_scope', () {
      final result = searchOps.search({'path_pattern': 'bin/tool.dart'});
      final json = parseResult(result);
      expect(json['status'], 'out_of_scope');
    });

    test('searchAnnotations with disallowed path_pattern returns out_of_scope', () {
      final result = searchOps.searchAnnotations({'path_pattern': 'bin/tool.dart'});
      final json = parseResult(result);
      expect(json['status'], 'out_of_scope');
    });
  });

  group('DiffOperations out_of_scope array', () {
    test('diff includes out_of_scope array for skipped files', () {
      final diffOps = DiffOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [p.join(tempDir.path, 'lib')],
      );

      final result = diffOps.diff({
        'directories': ['.'],
        'file_extensions': ['.dart'],
      });
      final json = parseResult(result);

      expect(json.containsKey('out_of_scope'), isTrue);
      final outOfScope = (json['out_of_scope'] as List).cast<String>();
      expect(outOfScope, contains('bin/tool.dart'));
      expect(outOfScope, contains('test/test_main.dart'));

      // In-scope files should be in added (not indexed yet)
      final added = (json['added'] as List).cast<String>();
      expect(added, contains('lib/main.dart'));
      expect(added, contains('lib/utils.dart'));
    });

    test('diff omits out_of_scope key when empty', () {
      final diffOps = DiffOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [
          p.join(tempDir.path, 'lib'),
          p.join(tempDir.path, 'bin'),
          p.join(tempDir.path, 'test'),
        ],
      );

      final result = diffOps.diff({
        'directories': ['.'],
        'file_extensions': ['.dart'],
      });
      final json = parseResult(result);
      expect(json.containsKey('out_of_scope'), isFalse);
    });
  });

  group('Missing config (no restrictions)', () {
    test('all operations are permissive when allowedPaths is empty', () {
      final indexOps = IndexOperations(
        database: database,
        workingDir: workingDir,
      );
      final browseOps = BrowseOperations(
        database: database,
        workingDir: workingDir,
      );
      final searchOps = SearchOperations(
        database: database,
        workingDir: workingDir,
      );

      // indexFile should succeed for any path
      final indexResult = indexOps.indexFile({
        'path': 'bin/tool.dart',
        'name': 'tool.dart',
        'file_type': 'dart',
      });
      final indexJson = parseResult(indexResult);
      expect(indexJson['success'], isTrue);

      // getFile should succeed
      final showResult = browseOps.getFile({'path': 'bin/tool.dart'});
      final showJson = parseResult(showResult);
      expect(showJson.containsKey('path'), isTrue);

      // dependencies should succeed
      final depsResult = searchOps.dependencies({'path': 'bin/tool.dart'});
      final depsJson = parseResult(depsResult);
      expect(depsJson.containsKey('dependencies'), isTrue);
    });
  });
}
