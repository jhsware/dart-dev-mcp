import 'dart:convert';
import 'dart:io';

import 'package:code_index_mcp/src/registry.dart';
import 'package:code_index_mcp/src/storage_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_helpers.dart';

/// End-to-end integration tests for the design §10 flows, driven through the
/// v2 handlers against an isolated temp `--data-root`. The Dart flows copy the
/// `test/fixtures/sample_project` fixture so the analyzer has a real
/// `pubspec.yaml` and resolvable `package:` imports.
void main() {
  group('non-Dart flows (yaml/md, no analyzer)', () {
    late TestIndex idx;

    setUp(() => idx = TestIndex.create());
    tearDown(() => idx.dispose());

    test('session-start: scan → index-files → search', () async {
      idx.writeFile('config/app.yaml', 'server:\n  host: localhost\n');
      idx.writeFile('shared/base.yaml', 'defaults:\n  retries: 3\n');

      // Scan discovers both files and plans them.
      final scan = idx.scanDirs();
      final planned =
          (scan['plan'] as List).map((e) => e['path'] as String).toSet();
      expect(planned, containsAll(<String>['config/app.yaml', 'shared/base.yaml']));

      // Agent indexes the planned files.
      final indexed = await idx.indexFiles([
        {
          'path': 'config/app.yaml',
          'language': 'yaml',
          'summary': 'App configuration for auth login',
          'tags': ['auth', 'config'],
        },
        {'path': 'shared/base.yaml', 'language': 'yaml', 'summary': 'Base config'},
      ]);
      expect(indexed['indexed'],
          containsAll(<String>['config/app.yaml', 'shared/base.yaml']));

      // Search finds the app config by its summary text.
      final res = jsonOf(idx.search.search({'query': 'auth login'}));
      expect((res['files'] as List).map((f) => f['path']),
          contains('config/app.yaml'));
    });

    test('stale-on-read: touching a fixture flips needs_reindex', () async {
      idx.writeFile('config/app.yaml', 'server:\n  host: localhost\n');
      await idx.indexFiles([
        {'path': 'config/app.yaml', 'language': 'yaml', 'summary': 'cfg'},
      ]);

      final fresh = jsonOf(idx.browse.getFile({'path': 'config/app.yaml'}));
      expect(fresh['needs_reindex'], isEmpty);
      expect(fresh['analysis_status'], 'fresh');

      // Mutate on disk (size changes) → the mtime+size short-circuit misses.
      idx.writeFile('config/app.yaml', 'server:\n  host: 0.0.0.0\n  port: 80\n');
      final stale = jsonOf(idx.browse.getFile({'path': 'config/app.yaml'}));
      expect(stale['needs_reindex'], isNotEmpty);
      expect((stale['needs_reindex'] as List).first['path'], 'config/app.yaml');
    });

    test('changed-file scan → re-index updates references', () async {
      idx.writeFile('build.yaml', 'targets:\n  app: 1\n');
      await idx.indexFiles([
        {
          'path': 'build.yaml',
          'language': 'yaml',
          'references': [
            {'symbol': 'json_serializable', 'qualifier': 'build_runner'},
          ],
        },
      ]);
      expect(
        idx.db
            .select('SELECT dot_path FROM symbol_references')
            .map((r) => r['dot_path']),
        contains('build_runner.json_serializable'),
      );

      // Change the file (size differs) → scan reports it as changed.
      idx.writeFile('build.yaml', 'targets:\n  app: 1\n  api: 2\n');
      final scan = idx.scanDirs();
      expect(scan['changed'], contains('build.yaml'));

      // Re-index with a different reference set; the old ref is replaced.
      await idx.indexFiles([
        {
          'path': 'build.yaml',
          'language': 'yaml',
          'references': [
            {'symbol': 'freezed', 'qualifier': 'build_runner'},
          ],
        },
      ]);
      final dotPaths = idx.db
          .select('SELECT dot_path FROM symbol_references')
          .map((r) => r['dot_path'])
          .toList();
      expect(dotPaths, contains('build_runner.freezed'));
      expect(dotPaths, isNot(contains('build_runner.json_serializable')));
    });

    test('rebuild:true drops the DB and re-plans every file', () async {
      idx.writeFile('a.yaml', 'a: 1\n');
      await idx.indexFiles([
        {'path': 'a.yaml', 'language': 'yaml'},
      ]);
      expect(idx.db.select('SELECT * FROM files'), isNotEmpty);

      final res = idx.scanDirs({
        'directories': ['.'],
        'rebuild': true,
      });
      expect(res['added'], contains('a.yaml'));
      expect(res['unchanged_count'], 0);
      // The replaced connection is a fresh schema-v2 database.
      expect(idx.db.select('PRAGMA user_version').first.values.first, 2);
      expect(idx.db.select('SELECT * FROM files'), isEmpty);
    });
  });

  group('storage isolation & registry', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ci_storage_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('two projects sharing a basename resolve to distinct data dirs', () {
      final a = Directory(p.join(tmp.path, 'x', 'app'))
        ..createSync(recursive: true);
      final b = Directory(p.join(tmp.path, 'y', 'app'))
        ..createSync(recursive: true);
      final dirA = dataDirFor(tmp.path, a.path);
      final dirB = dataDirFor(tmp.path, b.path);
      expect(p.basename(dirA), startsWith('app-'));
      expect(p.basename(dirB), startsWith('app-'));
      expect(dirA, isNot(dirB));
    });

    test('registry is rebuilt after the file is deleted', () {
      final a = Directory(p.join(tmp.path, 'one'))..createSync();
      final b = Directory(p.join(tmp.path, 'two'))..createSync();
      upsertProject(tmp.path, a.path);
      upsertProject(tmp.path, b.path);

      // Nuke the registry, then upsert again — it is rebuilt from scratch.
      File(p.join(tmp.path, 'registry.json')).deleteSync();
      upsertProject(tmp.path, a.path);

      final reg = File(p.join(tmp.path, 'registry.json'));
      expect(reg.existsSync(), isTrue);
      final projects = (jsonDecodeRegistry(reg)['projects'] as Map);
      expect(projects.containsKey(canonicalProjectPath(a.path)), isTrue);
    });
  });

  group('Dart flows (fixture project + analyzer)', () {
    late TestIndex idx;

    setUp(() async {
      final fixture = p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'sample_project',
      );
      idx = TestIndex.create(copyFixture: fixture);
      await idx.pubGet();
    });

    tearDown(() => idx.dispose());

    test('find-symbol → partial read returns the symbol line range', () async {
      await idx.indexFiles([
        {'path': 'lib/greeter.dart', 'language': 'dart'},
      ]);

      final res = jsonOf(idx.symbols.findSymbol({'name': 'Greeter'}));
      final match = (res['matches'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((m) => m['kind'] == 'class');
      expect(match['path'], 'lib/greeter.dart');
      final line = match['line'] as int;
      final endLine = match['end_line'] as int;
      expect(line, greaterThan(0));
      expect(endLine, greaterThanOrEqualTo(line));

      // "Partial read": slice exactly the reported range off disk.
      final allLines = idx.file('lib/greeter.dart').readAsLinesSync();
      final slice = allLines.sublist(line - 1, endLine).join('\n');
      expect(slice, contains('class Greeter'));
    });

    test('renaming a symbol refreshes its Dart dependents', () async {
      idx.writeFile('lib/consumer.dart', '''
import 'package:sample_project/greeter.dart';
Greeter? held;
''');
      await idx.indexFiles([
        {'path': 'lib/greeter.dart'},
        {'path': 'lib/consumer.dart'},
      ]);
      expect(
        idx.db
            .select("SELECT dot_path FROM symbol_references "
                "WHERE dot_path = 'sample_project.greeter.Greeter'"),
        isNotEmpty,
      );

      // Rename the public class and re-index only greeter.dart with refresh.
      idx.writeFile('lib/greeter.dart', 'class Welcomer {}\n');
      final res = await idx.indexFiles([
        {'path': 'lib/greeter.dart'},
      ], refreshDependents: true);

      expect(res['dependents_refreshed'], contains('lib/consumer.dart'));
      expect(
        idx.db.select("SELECT dot_path FROM symbol_references "
            "WHERE dot_path = 'sample_project.greeter.Greeter'"),
        isEmpty,
      );
    });
  });
}

/// Decode a `registry.json` file into a map (local helper for assertions).
Map<String, dynamic> jsonDecodeRegistry(File f) =>
    (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
