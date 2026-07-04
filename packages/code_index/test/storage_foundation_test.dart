import 'dart:convert';
import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'package:code_index_mcp/src/database.dart';
import 'package:code_index_mcp/src/hash_utils.dart';
import 'package:code_index_mcp/src/registry.dart';
import 'package:code_index_mcp/src/storage_paths.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('code_index_storage_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('storage_paths', () {
    test('sanitizeBasename replaces unsafe chars', () {
      expect(sanitizeBasename('my app!/v2'), 'my_app__v2');
      expect(sanitizeBasename('ok.name-1_2'), 'ok.name-1_2');
    });

    test('sha8 is 8 hex chars and deterministic', () {
      final a = sha8('/some/path');
      expect(a, hasLength(8));
      expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(a), isTrue);
      expect(sha8('/some/path'), a);
      expect(sha8('/other/path'), isNot(a));
    });

    test('two projects sharing a basename get distinct dirs', () {
      final root = tmp.path;
      final a = Directory(p.join(root, 'x', 'app'))..createSync(recursive: true);
      final b = Directory(p.join(root, 'y', 'app'))..createSync(recursive: true);

      final dirA = dataDirFor(root, a.path);
      final dirB = dataDirFor(root, b.path);

      expect(p.basename(dirA), startsWith('app-'));
      expect(p.basename(dirB), startsWith('app-'));
      expect(dirA, isNot(dirB));
    });

    test('dbPathFor points at code_index.db inside data dir', () {
      final proj = Directory(p.join(tmp.path, 'proj'))..createSync();
      final dbPath = dbPathFor(tmp.path, proj.path);
      expect(p.basename(dbPath), 'code_index.db');
      expect(p.dirname(dbPath), dataDirFor(tmp.path, proj.path));
    });

    test('ensureDataDir creates the directory recursively', () {
      final proj = Directory(p.join(tmp.path, 'proj'))..createSync();
      final dir = ensureDataDir(p.join(tmp.path, 'store'), proj.path);
      expect(dir.existsSync(), isTrue);
    });
  });

  group('hash_utils', () {
    test('computeFileHash returns sha256 hex', () {
      final f = File(p.join(tmp.path, 'a.txt'))..writeAsStringSync('hello');
      // Known sha256 of "hello".
      expect(computeFileHash(f),
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
    });

    test('isUnchanged short-circuits on matching mtime+size', () {
      final f = File(p.join(tmp.path, 'b.txt'))..writeAsStringSync('data');
      final stat = f.statSync();
      expect(
        isUnchanged(
          storedMtimeIso: stat.modified.toUtc().toIso8601String(),
          storedSize: stat.size,
          stat: stat,
        ),
        isTrue,
      );
    });

    test('isUnchanged false on size mismatch or missing stored values', () {
      final f = File(p.join(tmp.path, 'c.txt'))..writeAsStringSync('data');
      final stat = f.statSync();
      expect(
        isUnchanged(
          storedMtimeIso: stat.modified.toUtc().toIso8601String(),
          storedSize: stat.size + 1,
          stat: stat,
        ),
        isFalse,
      );
      expect(
        isUnchanged(storedMtimeIso: null, storedSize: stat.size, stat: stat),
        isFalse,
      );
    });
  });

  group('registry', () {
    test('upsertProject writes registry.json atomically', () {
      final root = tmp.path;
      final proj = Directory(p.join(root, 'proj'))..createSync();
      upsertProject(root, proj.path);

      final regFile = File(p.join(root, 'registry.json'));
      expect(regFile.existsSync(), isTrue);
      expect(File(p.join(root, 'registry.json.tmp')).existsSync(), isFalse);

      final reg = jsonDecode(regFile.readAsStringSync()) as Map;
      final projects = reg['projects'] as Map;
      final canonical = canonicalProjectPath(proj.path);
      expect(projects.containsKey(canonical), isTrue);
      final entry = projects[canonical] as Map;
      expect(entry['name'], 'proj');
      expect(entry['dir'], dataDirNameFor(proj.path));
    });

    test('upsertProject preserves created_at, refreshes last_opened_at', () {
      final root = tmp.path;
      final proj = Directory(p.join(root, 'proj'))..createSync();
      upsertProject(root, proj.path);
      final canonical = canonicalProjectPath(proj.path);
      final first = (jsonDecode(File(p.join(root, 'registry.json'))
          .readAsStringSync()) as Map)['projects'][canonical] as Map;

      upsertProject(root, proj.path);
      final second = (jsonDecode(File(p.join(root, 'registry.json'))
          .readAsStringSync()) as Map)['projects'][canonical] as Map;

      expect(second['created_at'], first['created_at']);
    });

    test('registry rebuilt lazily when corrupt', () {
      final root = tmp.path;
      File(p.join(root, 'registry.json')).writeAsStringSync('not json');
      final proj = Directory(p.join(root, 'proj'))..createSync();
      upsertProject(root, proj.path);
      final reg =
          jsonDecode(File(p.join(root, 'registry.json')).readAsStringSync())
              as Map;
      expect((reg['projects'] as Map), isNotEmpty);
    });

    test('meta.json round-trips and mismatch throws', () {
      final dataDir = Directory(p.join(tmp.path, 'data'))..createSync();
      final proj = Directory(p.join(tmp.path, 'proj'))..createSync();
      writeMeta(dataDir.path, proj.path, schemaVersion);

      final meta = readMeta(dataDir.path)!;
      expect(meta['project_path'], canonicalProjectPath(proj.path));
      expect(meta['schema_version'], schemaVersion);

      // Matching project is allowed.
      assertMetaMatches(dataDir.path, proj.path);

      // Different project throws.
      final other = Directory(p.join(tmp.path, 'other'))..createSync();
      expect(() => assertMetaMatches(dataDir.path, other.path),
          throwsA(isA<MetaMismatchError>()));
    });

    test('missing meta.json is allowed', () {
      final dataDir = Directory(p.join(tmp.path, 'empty'))..createSync();
      expect(readMeta(dataDir.path), isNull);
      expect(() => assertMetaMatches(dataDir.path, tmp.path), returnsNormally);
    });
  });

  group('database v2', () {
    test('initializeDatabase stamps user_version=2 and creates tables', () {
      final dbPath = p.join(tmp.path, 'code_index.db');
      final db = initializeDatabase(dbPath);
      final version = db.select('PRAGMA user_version').first.values.first;
      expect(version, 2);

      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type IN ('table')")
          .map((r) => r['name'])
          .toList();
      expect(tables, containsAll(<String>[
        'files',
        'symbols',
        'imports',
        'symbol_references',
        'annotations',
      ]));
      db.dispose();
    });

    test('openOrRebuild rebuilds when user_version mismatches', () {
      final dbPath = p.join(tmp.path, 'code_index.db');
      final db = sqlite3.open(dbPath);
      db.execute('PRAGMA user_version=1');
      db.execute('CREATE TABLE legacy (id TEXT)');
      db.dispose();

      final reopened = openOrRebuild(dbPath);
      final version = reopened.select('PRAGMA user_version').first.values.first;
      expect(version, 2);
      final legacy = reopened.select(
          "SELECT name FROM sqlite_master WHERE name='legacy'");
      expect(legacy, isEmpty);
      reopened.dispose();
    });

    test('openOrRebuild keeps a matching-version database', () {
      final dbPath = p.join(tmp.path, 'code_index.db');
      initializeDatabase(dbPath).dispose();
      final db = openOrRebuild(dbPath);
      expect(db.select('PRAGMA user_version').first.values.first, 2);
      db.dispose();
    });
  });
}
