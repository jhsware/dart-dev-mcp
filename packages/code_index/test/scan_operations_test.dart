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
  group('ScanOperations.scan', () {
    late Directory project;
    late Directory dataDir;
    late String dbPath;
    late Database db;
    late WriteOperations write;
    late ScanOperations scanOps;

    void write0(String relPath, String contents) {
      final f = File(p.join(project.path, relPath));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(contents);
    }

    Future<void> index(List<String> paths) async {
      await write.indexFiles({
        'files': [
          for (final path in paths) {'path': path},
        ],
        'refresh_dependents': false,
      });
    }

    void makeScanOps() {
      scanOps = ScanOperations(
        database: db,
        workingDir: project,
        dbPath: dbPath,
        onDatabaseReplaced: (newDb) => db = newDb,
      );
    }

    setUp(() {
      project = Directory.systemTemp.createTempSync('scan_project_');
      dataDir = Directory.systemTemp.createTempSync('scan_data_');
      dbPath = p.join(dataDir.path, 'code_index.db');
      db = initializeDatabase(dbPath);
      write = WriteOperations(database: db, workingDir: project);
      makeScanOps();
    });

    tearDown(() {
      db.dispose();
      project.deleteSync(recursive: true);
      dataDir.deleteSync(recursive: true);
    });

    test(
      'classifies added / changed / deleted and removes deleted rows',
      () async {
        write0('a.yaml', 'a: 1\n');
        write0('b.yaml', 'b: 1\n');
        await index(['a.yaml', 'b.yaml']);

        // Mutate b, add c, delete a.
        write0('b.yaml', 'b: 2\nb2: 3\n');
        write0('c.yaml', 'c: 1\n');
        File(p.join(project.path, 'a.yaml')).deleteSync();

        final res = _json(
          scanOps.scan({
            'directories': ['.'],
          }),
        );
        expect(res['added'], ['c.yaml']);
        expect(res['changed'], ['b.yaml']);
        expect(res['deleted'], ['a.yaml']);

        // remove_deleted defaults true → the row (and FTS row) are gone.
        final rows = db.select("SELECT path FROM files WHERE path = 'a.yaml'");
        expect(rows, isEmpty);
        final fts = db.select(
          "SELECT * FROM code_index_fts WHERE path = 'a.yaml'",
        );
        expect(fts, isEmpty);
      },
    );

    test('language-aware plan: dart → [1,3], others → [1,2,3]', () {
      write0('lib/new.dart', 'class A {}\n');
      write0('tool/build.yaml', 'targets: {}\n');

      final res = _json(
        scanOps.scan({
          'directories': ['.'],
        }),
      );
      final plan = (res['plan'] as List).cast<Map<String, dynamic>>();
      final byPath = {for (final e in plan) e['path'] as String: e['needs']};
      expect(byPath['lib/new.dart'], [1, 3]);
      expect(byPath['tool/build.yaml'], [1, 2, 3]);
      expect(res['summary']['files_to_index'], 2);
      expect(res['summary']['estimated_batches'], 1);
    });

    test('since pre-filter skips files older than the timestamp', () {
      write0('old.yaml', 'x: 1\n');
      final oldFile = File(p.join(project.path, 'old.yaml'));
      oldFile.setLastModifiedSync(DateTime.utc(2000, 1, 1));
      write0('fresh.yaml', 'y: 1\n');

      final res = _json(
        scanOps.scan({
          'directories': ['.'],
          'since': DateTime.utc(2020, 1, 1).toIso8601String(),
        }),
      );
      expect(res['added'], ['fresh.yaml']);
      expect(res['skipped_by_since'], 1);
    });

    test('verify forces rehash where the short-circuit would skip', () async {
      write0('same.yaml', 'a: 1\n');
      final f = File(p.join(project.path, 'same.yaml'));
      await index(['same.yaml']);

      // Rewrite with identical byte length (size unchanged), then point the
      // stored mtime at the *current* on-disk mtime so the mtime+size
      // short-circuit believes the file is unchanged even though its content
      // (and therefore its hash) now differs.
      f.writeAsStringSync('a: 2\n');
      final nowMtime = f.statSync().modified.toUtc().toIso8601String();
      db.execute("UPDATE files SET mtime = ? WHERE path = 'same.yaml'", [
        nowMtime,
      ]);

      final quiet = _json(
        scanOps.scan({
          'directories': ['.'],
        }),
      );
      expect(quiet['changed'], isEmpty);
      expect(quiet['unchanged_count'], 1);

      final forced = _json(
        scanOps.scan({
          'directories': ['.'],
          'verify': true,
        }),
      );
      expect(forced['changed'], ['same.yaml']);
    });

    test('rebuild recreates the DB and returns every file as added', () async {
      write0('a.yaml', 'a: 1\n');
      await index(['a.yaml']);
      expect(db.select('SELECT * FROM files'), isNotEmpty);

      final res = _json(
        scanOps.scan({
          'directories': ['.'],
          'rebuild': true,
        }),
      );
      expect(res['added'], ['a.yaml']);
      expect(res['changed'], isEmpty);
      expect(res['unchanged_count'], 0);
      // The replaced connection is fresh at schema v2 with the file re-added
      // to the plan.
      expect((res['plan'] as List).single['path'], 'a.yaml');
    });

    test('unchanged files are short-circuited (no reindex needed)', () async {
      write0('a.yaml', 'a: 1\n');
      await index(['a.yaml']);

      final res = _json(
        scanOps.scan({
          'directories': ['.'],
        }),
      );
      expect(res['added'], isEmpty);
      expect(res['changed'], isEmpty);
      expect(res['unchanged_count'], 1);
      expect(res['plan'], isEmpty);
    });
  });
}
