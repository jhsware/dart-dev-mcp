import 'dart:convert';
import 'dart:io';

import 'package:code_index_mcp/code_index_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Tests for sharing the code-index store across git worktrees:
/// canonicalization of `.worktrees/<slug>` paths in storage-path
/// derivation, stat refresh after a fresh checkout resets every mtime,
/// and pruning of orphaned stores.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('code_index_worktree_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('worktree canonicalization', () {
    test('worktree checkout root maps to the main repo store', () {
      final repo = Directory(p.join(tmp.path, 'repo'))..createSync();
      final worktree = Directory(p.join(repo.path, '.worktrees', 'my-branch'))
        ..createSync(recursive: true);

      expect(
          canonicalProjectPath(worktree.path), canonicalProjectPath(repo.path));
      expect(dataDirNameFor(worktree.path), dataDirNameFor(repo.path));
      expect(
          dbPathFor(tmp.path, worktree.path), dbPathFor(tmp.path, repo.path));
    });

    test('sub-package inside a worktree maps to the main sub-package store',
        () {
      final repo = Directory(p.join(tmp.path, 'repo'))..createSync();
      final pkg = Directory(p.join(repo.path, 'pkg'))..createSync();
      final worktreePkg =
          Directory(p.join(repo.path, '.worktrees', 'my-branch', 'pkg'))
            ..createSync(recursive: true);

      expect(
          canonicalProjectPath(worktreePkg.path), canonicalProjectPath(pkg.path));
      expect(dataDirNameFor(worktreePkg.path), dataDirNameFor(pkg.path));
    });

    test('non-worktree paths resolve as before', () {
      final proj = Directory(p.join(tmp.path, 'proj'))..createSync();
      expect(canonicalProjectPath(proj.path),
          Directory(proj.path).resolveSymbolicLinksSync());
    });

    test('matching is segment-exact: .worktrees-backup is not stripped', () {
      final backup = Directory(p.join(tmp.path, '.worktrees-backup', 'proj'))
        ..createSync(recursive: true);
      expect(canonicalProjectPath(backup.path), contains('.worktrees-backup'));
    });

    test('meta.json written from the main checkout matches the worktree', () {
      final repo = Directory(p.join(tmp.path, 'repo'))..createSync();
      final worktree = Directory(p.join(repo.path, '.worktrees', 'fam-1'))
        ..createSync(recursive: true);
      final dataDir = ensureDataDir(tmp.path, repo.path).path;
      writeMeta(dataDir, repo.path, schemaVersion);

      // Opening the same store via the worktree spelling must not throw.
      expect(() => assertMetaMatches(dataDir, worktree.path), returnsNormally);
    });
  });

  group('fresh-checkout rescan (reset mtimes)', () {
    Map<String, dynamic> scanJson(CallToolResult result) =>
        jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;

    test('populated store: full re-hash once, stat short-circuit afterwards',
        () async {
      final project = Directory(p.join(tmp.path, 'proj'))..createSync();
      const fileCount = 200;
      for (var i = 0; i < fileCount; i++) {
        File(p.join(project.path, 'f$i.yaml'))
            .writeAsStringSync('key$i: value$i\n' * 20);
      }

      final dbPath = p.join(tmp.path, 'code_index.db');
      final db = initializeDatabase(dbPath);
      addTearDown(db.dispose);

      await WriteOperations(database: db, workingDir: project).indexFiles({
        'files': [
          for (var i = 0; i < fileCount; i++)
            {'path': 'f$i.yaml', 'language': 'yaml'},
        ],
        'refresh_dependents': false,
      });

      // Simulate a fresh checkout: every mtime changes, contents identical.
      final touched = DateTime.now().add(const Duration(seconds: 5));
      for (var i = 0; i < fileCount; i++) {
        File(p.join(project.path, 'f$i.yaml')).setLastModifiedSync(touched);
      }

      ScanOperations ops() => ScanOperations(
            database: db,
            workingDir: project,
            dbPath: dbPath,
          );

      // First scan after the "checkout": the mtime+size short-circuit
      // misses, every file is hashed, digests match — nothing to re-index.
      final sw = Stopwatch()..start();
      final first = scanJson(ops().scan({}));
      final hashPassMs = sw.elapsedMilliseconds;
      expect(first['added'], isEmpty);
      expect(first['changed'], isEmpty);
      expect(first['unchanged_count'], fileCount);

      // The stored stat must have been refreshed to the new mtime so the
      // next scan can short-circuit without hashing.
      final storedMtime = db
          .select('SELECT mtime FROM files WHERE path = ?', ['f0.yaml'])
          .first['mtime'] as String;
      expect(DateTime.parse(storedMtime).toUtc(),
          File(p.join(project.path, 'f0.yaml')).statSync().modified.toUtc());

      // Second scan short-circuits on mtime+size.
      sw.reset();
      final second = scanJson(ops().scan({}));
      final statPassMs = sw.elapsedMilliseconds;
      expect(second['added'], isEmpty);
      expect(second['changed'], isEmpty);
      expect(second['unchanged_count'], fileCount);

      // Documentation datapoint for the task (not an assertion — timings
      // vary by machine).
      // ignore: avoid_print
      print('rescan of $fileCount identical files: '
          'hash pass ${hashPassMs}ms, stat pass ${statPassMs}ms');
    });
  });

  group('pruneOrphanedStores', () {
    test('dry run reports orphans without deleting', () {
      final root = p.join(tmp.path, 'store');
      final alive = Directory(p.join(tmp.path, 'alive-proj'))..createSync();
      final dead = Directory(p.join(tmp.path, 'dead-proj'))..createSync();

      final aliveDir = ensureDataDir(root, alive.path).path;
      writeMeta(aliveDir, alive.path, schemaVersion);
      upsertProject(root, alive.path);

      final deadDir = ensureDataDir(root, dead.path).path;
      writeMeta(deadDir, dead.path, schemaVersion);
      upsertProject(root, dead.path);

      // A directory without meta.json cannot be identified.
      Directory(p.join(root, 'mystery-dir')).createSync();

      dead.deleteSync(); // the source project disappears

      final report = pruneOrphanedStores(root);
      expect(report['deleted'], isFalse);
      expect(report['orphans'], hasLength(1));
      expect((report['orphans'] as List).first['dir'], p.basename(deadDir));
      expect(report['kept_count'], 1);
      expect(report['unidentified'], ['mystery-dir']);
      expect(Directory(deadDir).existsSync(), isTrue); // dry run keeps it
    });

    test('delete=true removes orphan stores and their registry entries', () {
      final root = p.join(tmp.path, 'store');
      final alive = Directory(p.join(tmp.path, 'alive-proj'))..createSync();
      final dead = Directory(p.join(tmp.path, 'dead-proj'))..createSync();
      final aliveCanonical = canonicalProjectPath(alive.path);
      final deadCanonical = canonicalProjectPath(dead.path);

      final aliveDir = ensureDataDir(root, alive.path).path;
      writeMeta(aliveDir, alive.path, schemaVersion);
      upsertProject(root, alive.path);

      final deadDir = ensureDataDir(root, dead.path).path;
      writeMeta(deadDir, dead.path, schemaVersion);
      upsertProject(root, dead.path);

      dead.deleteSync();

      final report = pruneOrphanedStores(root, delete: true);
      expect(report['deleted'], isTrue);
      expect(report['orphans'], hasLength(1));
      expect(Directory(deadDir).existsSync(), isFalse);
      expect(Directory(aliveDir).existsSync(), isTrue);

      final registry = jsonDecode(
              File(p.join(root, 'registry.json')).readAsStringSync())
          as Map<String, dynamic>;
      final projects = registry['projects'] as Map<String, dynamic>;
      expect(projects.containsKey(aliveCanonical), isTrue);
      expect(projects.containsKey(deadCanonical), isFalse);
    });

    test('missing data root returns an empty report', () {
      final report = pruneOrphanedStores(p.join(tmp.path, 'does-not-exist'));
      expect(report['orphans'], isEmpty);
      expect(report['kept_count'], 0);
      expect(report['unidentified'], isEmpty);
    });
  });
}
