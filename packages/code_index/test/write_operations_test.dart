import 'dart:convert';
import 'dart:io';

import 'package:code_index_mcp/code_index_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Map<String, dynamic> _json(CallToolResult r) =>
    jsonDecode((r.content.first as TextContent).text) as Map<String, dynamic>;

void main() {
  group('record_normalize (pure)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('rec_norm_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('declared reference → dot-path with resolution=declared', () {
      final f = File(p.join(tmp.path, 'build.yaml'))
        ..writeAsStringSync('targets:\n  x: 1\n');
      final rec = normalizeRecord(
        record: {
          'references': [
            {'symbol': 'json_serializable', 'qualifier': 'build_runner', 'count': 2},
            {'symbol': 'Widget', 'qualifier': 'package:flutter/material.dart'},
            {'symbol': 'Loose'},
          ],
        },
        relPath: 'build.yaml',
        file: f,
        name: 'build.yaml',
        fileType: 'yaml',
      );
      final refs = {for (final r in rec.references) r.symbol: r};
      expect(refs['json_serializable']!.dotPath, 'build_runner.json_serializable');
      expect(refs['json_serializable']!.resolution, 'declared');
      expect(refs['json_serializable']!.count, 2);
      expect(refs['Widget']!.dotPath, 'flutter.material.Widget');
      expect(refs['Loose']!.dotPath, 'unknown.Loose');
    });

    test('out-of-range symbol line is cleared and warned', () {
      final f = File(p.join(tmp.path, 'conf.toml'))
        ..writeAsStringSync('a = 1\nb = 2\n');
      final rec = normalizeRecord(
        record: {
          'symbols': [
            {'name': 'targets', 'kind': 'key', 'line': 1, 'end_line': 300},
          ],
        },
        relPath: 'conf.toml',
        file: f,
        name: 'conf.toml',
        fileType: 'toml',
      );
      expect(rec.symbols.single.line, 1);
      expect(rec.symbols.single.endLine, isNull);
      expect(rec.warnings.single, contains('end_line 300 > line_count'));
    });
  });

  group('index-files write path', () {
    late Directory project;
    late Directory dataDir;
    late Database db;
    late WriteOperations ops;

    Future<void> pubGet() async {
      final r = await Process.run('dart', ['pub', 'get'],
          workingDirectory: project.path);
      expect(r.exitCode, 0, reason: 'pub get failed: ${r.stderr}');
    }

    setUp(() async {
      project = await Directory.systemTemp.createTemp('wo_project_');
      dataDir = await Directory.systemTemp.createTemp('wo_data_');
      await File(p.join(project.path, 'pubspec.yaml')).writeAsString('''
name: test_app
environment:
  sdk: ^3.9.3
''');
      await Directory(p.join(project.path, 'lib')).create();
      db = initializeDatabase(p.join(dataDir.path, 'code_index.db'));
      ops = WriteOperations(database: db, workingDir: project);
    });

    tearDown(() async {
      db.dispose();
      await project.delete(recursive: true);
      await dataDir.delete(recursive: true);
    });

    test('non-Dart declared refs + line clamp warning surface in response',
        () async {
      await File(p.join(project.path, 'build.yaml'))
          .writeAsString('targets:\n  app: 1\n');
      final res = _json(await ops.indexFiles({
        'files': [
          {
            'path': 'build.yaml',
            'language': 'yaml',
            'summary': 'build config',
            'tags': ['build', 'codegen'],
            'symbols': [
              {'name': 'targets', 'kind': 'key', 'line': 1, 'end_line': 99},
            ],
            'references': [
              {'symbol': 'json_serializable', 'qualifier': 'build_runner'},
            ],
          }
        ],
        'refresh_dependents': false,
      }));
      expect(res['indexed'], ['build.yaml']);
      expect((res['warnings'] as List).single['warning'],
          contains('end_line 99 > line_count'));

      final ref = db.select(
          'SELECT dot_path, resolution FROM symbol_references').first;
      expect(ref['dot_path'], 'build_runner.json_serializable');
      expect(ref['resolution'], 'declared');
      final fileRow = db.select('SELECT layers_present FROM files').first;
      expect(jsonDecode(fileRow['layers_present'] as String),
          containsAll(<int>[0, 1, 2]));
    });

    test('Dart structure computed by extractor; agent structure ignored',
        () async {
      await File(p.join(project.path, 'lib', 'greeter.dart')).writeAsString('''
class Greeter {
  String greet() => 'hi';
}
''');
      await pubGet();
      final res = _json(await ops.indexFiles({
        'files': [
          {
            'path': 'lib/greeter.dart',
            'language': 'dart',
            'summary': 'greets',
            'symbol_summaries': {'Greeter': 'The greeter.'},
            // Bogus agent structure that must be IGNORED for Dart:
            'symbols': [
              {'name': 'BOGUS', 'kind': 'class'}
            ],
          }
        ],
        'refresh_dependents': false,
      }));
      expect(res['indexed'], ['lib/greeter.dart']);
      final names = db
          .select('SELECT name FROM symbols')
          .map((r) => r['name'])
          .toList();
      expect(names, contains('Greeter'));
      expect(names, isNot(contains('BOGUS')));
      final summ = db.select(
          "SELECT summary FROM symbols WHERE name = 'Greeter'").first;
      expect(summ['summary'], 'The greeter.');
    });

    test('renamed symbol refreshes direct Dart dependents', () async {
      final greeter = File(p.join(project.path, 'lib', 'greeter.dart'));
      await greeter.writeAsString('class Greeter {}\n');
      await File(p.join(project.path, 'lib', 'consumer.dart')).writeAsString('''
import 'package:test_app/greeter.dart';
Greeter? held;
''');
      await pubGet();

      await ops.indexFiles({
        'files': [
          {'path': 'lib/greeter.dart'},
          {'path': 'lib/consumer.dart'},
        ],
        'refresh_dependents': false,
      });
      final before = db.select(
          "SELECT dot_path FROM symbol_references WHERE dot_path LIKE 'test_app.greeter.%'");
      expect(before.map((r) => r['dot_path']),
          contains('test_app.greeter.Greeter'));

      // Rename the public class and re-index only greeter.dart.
      await greeter.writeAsString('class Welcomer {}\n');
      final res = _json(await ops.indexFiles({
        'files': [
          {'path': 'lib/greeter.dart'},
        ],
      }));

      // (a) The changed file's declarations reflect the new name.
      final greeterSymbols =
          db.select('SELECT name FROM symbols').map((r) => r['name']).toList();
      expect(greeterSymbols, contains('Welcomer'));
      expect(greeterSymbols, isNot(contains('Greeter')));

      // (b) The importer was refreshed and its stale reference dropped.
      expect(res['dependents_refreshed'], contains('lib/consumer.dart'));
      final after = db.select(
          "SELECT dot_path FROM symbol_references WHERE dot_path = 'test_app.greeter.Greeter'");
      expect(after, isEmpty);
      final consumer = db.select(
          "SELECT structure_refreshed_at FROM files WHERE path = 'lib/consumer.dart'").first;
      expect(consumer['structure_refreshed_at'], isNotNull);
    });
  });
}
