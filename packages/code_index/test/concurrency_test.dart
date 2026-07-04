import 'dart:io';

import 'package:code_index_mcp/code_index_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// WAL concurrency smoke test: two independent connections to the same project
/// database read and write without hitting `database is locked` (design §3.3 —
/// WAL + a 5s busy timeout). Each connection is opened with the standard
/// PRAGMAs applied by `initializeDatabase` / `openOrRebuild`.
void main() {
  test('two WAL connections read and write the same project DB', () async {
    final project = Directory.systemTemp.createTempSync('conc_proj_');
    final dataDir = Directory.systemTemp.createTempSync('conc_data_');
    final dbPath = p.join(dataDir.path, 'code_index.db');

    final conn1 = initializeDatabase(dbPath);
    final conn2 = openOrRebuild(dbPath); // matching version → shared, not rebuilt

    File(p.join(project.path, 'a.yaml')).writeAsStringSync('a: 1\n');
    File(p.join(project.path, 'b.yaml')).writeAsStringSync('b: 1\n');

    final w1 = WriteOperations(database: conn1, workingDir: project);
    final w2 = WriteOperations(database: conn2, workingDir: project);

    // conn1 writes; conn2 observes the committed row.
    await w1.indexFiles({
      'files': [
        {'path': 'a.yaml', 'language': 'yaml'},
      ],
      'refresh_dependents': false,
    });
    expect(conn2.select('SELECT COUNT(*) AS c FROM files').first['c'], 1);

    // conn2 writes; conn1 observes it — no lock contention under WAL.
    await w2.indexFiles({
      'files': [
        {'path': 'b.yaml', 'language': 'yaml'},
      ],
      'refresh_dependents': false,
    });
    expect(conn1.select('SELECT COUNT(*) AS c FROM files').first['c'], 2);

    conn1.dispose();
    conn2.dispose();
    project.deleteSync(recursive: true);
    dataDir.deleteSync(recursive: true);
  });
}
