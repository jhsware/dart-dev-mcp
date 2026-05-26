import 'dart:convert';
import 'dart:io';

import 'package:code_index_mcp/code_index_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// End-to-end integration tests that exercise the architecture-doc §10 flows
/// through IndexOperations + BrowseOperations + AutoScanOperations without
/// MCP transport.
///
/// Uses the fixture project at `test/fixtures/sample_project/` so the
/// analyzer has a real pubspec.yaml and resolvable imports.
void main() {
  late Database database;
  late Directory tempDir;
  late Directory workingDir;
  late String dbPath;

  late IndexOperations indexOps;
  late BrowseOperations browseOps;
  late AutoScanOperations autoScanOps;

  /// Copy the fixture project into a temp directory so tests can mutate files.
  void copyFixture(String src, String dst) {
    final srcDir = Directory(src);
    for (final entity in srcDir.listSync(recursive: true)) {
      final relPath = p.relative(entity.path, from: src);
      if (entity is File) {
        final dest = File(p.join(dst, relPath));
        dest.parent.createSync(recursive: true);
        entity.copySync(dest.path);
      }
    }
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('code_index_integration_');
    workingDir = tempDir;

    // Copy fixture project into temp dir
    final fixtureDir = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'sample_project',
    );
    copyFixture(fixtureDir, tempDir.path);

    // Use file-backed DB for auto-scan rebuild support
    dbPath = p.join(tempDir.path, '.db', 'code_index.db');
    Directory(p.dirname(dbPath)).createSync(recursive: true);
    database = initializeDatabase(dbPath);

    indexOps = IndexOperations(database: database, workingDir: workingDir);
    browseOps = BrowseOperations(database: database, workingDir: workingDir);
    autoScanOps = AutoScanOperations(
      database: database,
      workingDir: workingDir,
      dbPath: dbPath,
      onDatabaseReplaced: (newDb) {
        database = newDb;
        // Recreate ops with the new DB handle
        indexOps = IndexOperations(database: database, workingDir: workingDir);
        browseOps = BrowseOperations(database: database, workingDir: workingDir);
      },
    );
  });

  tearDown(() {
    try {
      closeDatabase(database);
    } catch (_) {}
    tempDir.deleteSync(recursive: true);
  });

  Map<String, dynamic> parseResult(dynamic result) {
    final text = result.content.first.toJson()['text'] as String;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  group('End-to-end: auto-scan → auto-index → get-file', () {
    test('first-time scan discovers all files and produces a plan', () {
      final result = autoScanOps.autoScan({
        'directories': ['lib'],
        'file_extensions': ['.dart'],
      });
      final data = parseResult(result);

      expect(data['added'], isA<List>());
      final added = (data['added'] as List).cast<String>();
      expect(added, contains('lib/greeter.dart'));
      expect(added, contains('lib/utils.dart'));

      final plan = (data['plan'] as List).cast<Map<String, dynamic>>();
      expect(plan.length, added.length);
      for (final entry in plan) {
        expect(entry['path'], isA<String>());
        expect(entry['needs'], isA<List>());
      }

      final summary = data['summary'] as Map<String, dynamic>;
      expect(summary['files_to_analyze'], added.length);
    });

    test('batched auto-index populates all layers for Dart files', () async {
      // Step 1: scan
      final scanResult = autoScanOps.autoScan({
        'directories': ['lib'],
        'file_extensions': ['.dart'],
      });
      final scanData = parseResult(scanResult);
      final plan = (scanData['plan'] as List).cast<Map<String, dynamic>>();

      // Step 2: auto-index each file in the plan (simulates agent batch)
      for (final entry in plan) {
        final path = entry['path'] as String;
        final result = await indexOps.autoIndex({
          'path': path,
          'layers': [0, 1, 2, 3],
          'short_summary': 'Auto-indexed $path',
        });
        final data = parseResult(result);
        expect(data['success'], isTrue);
        expect(data['file']['layers_present'], contains(0));
        expect(data['file']['layers_present'], contains(1));
        expect(data['file']['layers_present'], contains(2));
      }

      // Step 3: verify all files are now in the DB
      final files = database.select('SELECT path FROM files ORDER BY path');
      expect(files.length, plan.length);
    });

    test('get-file returns layered data after indexing', () async {
      // Index greeter.dart
      await indexOps.autoIndex({
        'path': 'lib/greeter.dart',
        'layers': [0, 1, 2, 3],
        'short_summary': 'A greeting service module',
        'symbol_summaries': {
          'Greeter': 'A class that produces greetings',
          'runGreeter': 'Top-level function to run a greeter',
        },
      });

      // Layer 0 + 1: metadata + summary
      final r01 = parseResult(browseOps.getFile({
        'path': 'lib/greeter.dart',
        'layers': [0, 1],
      }));
      expect(r01['path'], 'lib/greeter.dart');
      expect(r01['file_type'], 'dart');
      expect(r01['size_bytes'], isA<int>());
      expect(r01['short_summary'], 'A greeting service module');
      expect(r01['needs_reindex'], isEmpty);

      // Layer 0 + 2 + 3: declarations with descriptions
      final r023 = parseResult(browseOps.getFile({
        'path': 'lib/greeter.dart',
        'layers': [0, 2, 3],
      }));
      final exports = (r023['exports'] as List).cast<Map<String, dynamic>>();
      final exportNames = exports.map((e) => e['name']).toSet();
      expect(exportNames, contains('Greeter'));
      expect(exportNames, contains('runGreeter'));
      expect(exportNames, contains('Mood'));

      // Symbol summaries should be present (layer 3)
      final greeterExport = exports.firstWhere(
        (e) => e['name'] == 'Greeter' && e['kind'] == 'class',
      );
      expect(greeterExport['description'], 'A class that produces greetings');

      // Imports should be present
      final imports = (r023['imports'] as List).cast<String>();
      expect(imports, contains('dart:io'));
      expect(imports, contains('package:path/path.dart'));

      // Variables should be present
      final variables = (r023['variables'] as List).cast<Map<String, dynamic>>();
      final varNames = variables.map((v) => v['name']).toSet();
      expect(varNames, contains('defaultLocale'));

      // Layer 4: public API only (filters _private)
      final r04 = parseResult(browseOps.getFile({
        'path': 'lib/greeter.dart',
        'layers': [0, 4],
      }));
      final pubExports = (r04['exports'] as List).cast<Map<String, dynamic>>();
      final pubNames = pubExports.map((e) => e['name']).toSet();
      // All exports in greeter.dart are public, so all should appear
      expect(pubNames, contains('Greeter'));
      expect(pubNames, contains('runGreeter'));
    });

    test('on-disk edit causes get-file to return needs_reindex', () async {
      // Index greeter.dart
      await indexOps.autoIndex({
        'path': 'lib/greeter.dart',
        'layers': [0, 1, 2],
        'short_summary': 'Greeting module',
      });

      // Verify fresh
      final fresh = parseResult(browseOps.getFile({
        'path': 'lib/greeter.dart',
        'layers': [0, 1, 2],
      }));
      expect(fresh['needs_reindex'], isEmpty);
      expect(fresh['analysis_status'], 'fresh');

      // Modify on disk
      final file = File(p.join(tempDir.path, 'lib', 'greeter.dart'));
      file.writeAsStringSync('// modified\n${file.readAsStringSync()}');

      // Now get-file should report stale
      final stale = parseResult(browseOps.getFile({
        'path': 'lib/greeter.dart',
        'layers': [0, 1, 2],
      }));
      expect(stale['needs_reindex'], isNotEmpty);
      final reindexEntry = (stale['needs_reindex'] as List).first
          as Map<String, dynamic>;
      expect(reindexEntry['path'], 'lib/greeter.dart');
      expect(reindexEntry['reason'], 'changed');
    });

    test('out_of_scope response for path outside allowed paths', () async {
      // Create ops restricted to lib/ only
      final allowedDir = p.join(tempDir.path, 'lib');
      final restrictedIndex = IndexOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [allowedDir],
      );
      final restrictedBrowse = BrowseOperations(
        database: database,
        workingDir: workingDir,
        allowedPaths: [allowedDir],
      );

      // auto-index on out-of-scope path
      final indexResult = await restrictedIndex.autoIndex({
        'path': 'pubspec.yaml',
      });
      final indexData = parseResult(indexResult);
      expect(indexData['status'], 'out_of_scope');
      expect(indexData['path'], 'pubspec.yaml');
      expect(indexData['allowed_paths'], isA<List>());

      // get-file on out-of-scope path
      final browseResult = restrictedBrowse.getFile({
        'path': 'pubspec.yaml',
      });
      final browseData = parseResult(browseResult);
      expect(browseData['status'], 'out_of_scope');
    });

    test('layer 4 filters private symbols from utils.dart', () async {
      await indexOps.autoIndex({
        'path': 'lib/utils.dart',
        'layers': [0, 1, 2],
        'short_summary': 'Utility helpers',
      });

      // Layer 4 should exclude _internalNormalize
      final result = parseResult(browseOps.getFile({
        'path': 'lib/utils.dart',
        'layers': [0, 4],
      }));
      final exports = (result['exports'] as List).cast<Map<String, dynamic>>();
      final names = exports.map((e) => e['name'] as String).toSet();

      expect(names, contains('capitalize'));
      expect(names, contains('normalize'));
      expect(names, isNot(contains('_internalNormalize')));
    });

    test('re-scan after indexing shows zero files_to_analyze', () async {
      // Scan + index all files
      final scanResult = autoScanOps.autoScan({
        'directories': ['lib'],
        'file_extensions': ['.dart'],
      });
      final plan = (parseResult(scanResult)['plan'] as List)
          .cast<Map<String, dynamic>>();

      for (final entry in plan) {
        await indexOps.autoIndex({
          'path': entry['path'],
          'layers': [0, 1, 2],
          'short_summary': 'Indexed',
        });
      }

      // Re-scan should show nothing to do
      final reScan = autoScanOps.autoScan({
        'directories': ['lib'],
        'file_extensions': ['.dart'],
      });
      final reScanData = parseResult(reScan);
      expect(reScanData['summary']['files_to_analyze'], 0);
      expect(reScanData['plan'], isEmpty);
    });
  });
}
