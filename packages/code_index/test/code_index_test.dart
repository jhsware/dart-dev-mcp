import 'dart:convert';
import 'dart:io';

import 'package:code_index_mcp/src/database.dart';
import 'package:code_index_mcp/src/hash_utils.dart';
import 'package:code_index_mcp/src/record_normalize.dart';
import 'package:code_index_mcp/src/registry.dart';
import 'package:code_index_mcp/src/storage_paths.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Unit tests for the v2 storage foundation: schema versioning, the
/// sha256 + mtime/size short-circuit, the registry/meta atomic writes, and the
/// pure `normalizeRecord` layer-0 pass (dot-path normalization + line-range
/// clamping). Every test runs against a fresh temp directory so nothing
/// touches the real `~/.code-index`.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('code_index_unit_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('schema version', () {
    test('initializeDatabase stamps user_version = 2', () {
      final db = initializeDatabase(p.join(tmp.path, 'code_index.db'));
      addTearDown(db.dispose);
      expect(db.select('PRAGMA user_version').first.values.first, 2);
    });

    test('openOrRebuild discards a database at a mismatched version', () {
      final dbPath = p.join(tmp.path, 'code_index.db');
      final stale = sqlite3.open(dbPath);
      stale.execute('PRAGMA user_version = 1');
      stale.execute('CREATE TABLE legacy (id TEXT)');
      stale.dispose();

      final rebuilt = openOrRebuild(dbPath);
      addTearDown(rebuilt.dispose);
      expect(rebuilt.select('PRAGMA user_version').first.values.first, 2);
      expect(
        rebuilt.select("SELECT name FROM sqlite_master WHERE name = 'legacy'"),
        isEmpty,
      );
      // The current schema is present.
      expect(rebuilt.select("SELECT name FROM sqlite_master WHERE name = 'files'"),
          isNotEmpty);
    });

    test('openOrRebuild keeps a database already at the current version', () {
      final dbPath = p.join(tmp.path, 'code_index.db');
      initializeDatabase(dbPath).dispose();
      final reopened = openOrRebuild(dbPath);
      addTearDown(reopened.dispose);
      expect(reopened.select('PRAGMA user_version').first.values.first, 2);
    });
  });

  group('hash short-circuit', () {
    test('computeFileHash is the sha256 of the file bytes', () {
      final f = File(p.join(tmp.path, 'a.txt'))..writeAsStringSync('hello');
      expect(
        computeFileHash(f),
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );
    });

    test('isUnchanged skips rehashing when mtime + size both match', () {
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

    test('isUnchanged forces a rehash on size drift or missing metadata', () {
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

  group('registry / meta atomic read-modify-write', () {
    test('upsertProject writes registry.json atomically (no .tmp left behind)',
        () {
      final proj = Directory(p.join(tmp.path, 'proj'))..createSync();
      upsertProject(tmp.path, proj.path);

      expect(File(p.join(tmp.path, 'registry.json')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'registry.json.tmp')).existsSync(), isFalse);

      final reg = jsonDecode(
        File(p.join(tmp.path, 'registry.json')).readAsStringSync(),
      ) as Map;
      final canonical = canonicalProjectPath(proj.path);
      expect((reg['projects'] as Map).containsKey(canonical), isTrue);
    });

    test('a second upsert preserves created_at (read-modify-write)', () {
      final proj = Directory(p.join(tmp.path, 'proj'))..createSync();
      final canonical = canonicalProjectPath(proj.path);
      upsertProject(tmp.path, proj.path);
      final first = (jsonDecode(File(p.join(tmp.path, 'registry.json'))
          .readAsStringSync()) as Map)['projects'][canonical] as Map;
      upsertProject(tmp.path, proj.path);
      final second = (jsonDecode(File(p.join(tmp.path, 'registry.json'))
          .readAsStringSync()) as Map)['projects'][canonical] as Map;
      expect(second['created_at'], first['created_at']);
    });

    test('a corrupt registry is rebuilt lazily on the next upsert', () {
      File(p.join(tmp.path, 'registry.json')).writeAsStringSync('{ not json');
      final proj = Directory(p.join(tmp.path, 'proj'))..createSync();
      upsertProject(tmp.path, proj.path);
      final reg = jsonDecode(
        File(p.join(tmp.path, 'registry.json')).readAsStringSync(),
      ) as Map;
      expect(reg['projects'] as Map, isNotEmpty);
    });

    test('meta.json round-trips and a foreign project is rejected', () {
      final dataDir = Directory(p.join(tmp.path, 'data'))..createSync();
      final proj = Directory(p.join(tmp.path, 'proj'))..createSync();
      writeMeta(dataDir.path, proj.path, schemaVersion);

      final meta = readMeta(dataDir.path)!;
      expect(meta['project_path'], canonicalProjectPath(proj.path));
      expect(meta['schema_version'], schemaVersion);
      expect(() => assertMetaMatches(dataDir.path, proj.path), returnsNormally);

      final other = Directory(p.join(tmp.path, 'other'))..createSync();
      expect(
        () => assertMetaMatches(dataDir.path, other.path),
        throwsA(isA<MetaMismatchError>()),
      );
    });
  });

  group('normalizeRecord (layer 0)', () {
    test('declared references become dot-paths with resolution = declared', () {
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
      final byName = {for (final r in rec.references) r.symbol: r};
      expect(byName['json_serializable']!.dotPath,
          'build_runner.json_serializable');
      expect(byName['json_serializable']!.resolution, 'declared');
      expect(byName['json_serializable']!.count, 2);
      expect(byName['Widget']!.dotPath, 'flutter.material.Widget');
      expect(byName['Loose']!.dotPath, 'unknown.Loose');
    });

    test('an out-of-range symbol end_line is cleared and warned', () {
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
}
