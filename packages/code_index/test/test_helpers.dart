import 'dart:convert';
import 'dart:io';

import 'package:jhsware_code_code_index/code_index_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Decode the JSON payload carried by a [CallToolResult].
Map<String, dynamic> jsonOf(CallToolResult r) =>
    jsonDecode((r.content.first as TextContent).text) as Map<String, dynamic>;

/// An isolated v2 code-index bound to a throwaway project directory and its
/// own temp `--data-root`.
///
/// Every harness creates the project *and* the data directory under
/// [Directory.systemTemp], so a test never reads or writes the real
/// `~/.code-index`. Construct with [TestIndex.create] in `setUp` and call
/// [dispose] in `tearDown`.
///
/// The [ScanOperations] `rebuild` path swaps the underlying [Database]; the
/// harness re-wires every handler through `onDatabaseReplaced` so callers keep
/// using `harness.search` / `harness.browse` after a rebuild.
class TestIndex {
  final Directory project;
  final Directory dataRoot;
  final String dbPath;
  List<String> allowedPaths;
  Database db;

  late WriteOperations write;
  late ScanOperations scan;
  late BrowseOperations browse;
  late SearchOperations search;
  late SymbolQueries symbols;
  late GraphQueries graph;

  TestIndex._(
    this.project,
    this.dataRoot,
    this.dbPath,
    this.db,
    this.allowedPaths,
  ) {
    _wire();
  }

  /// Spin up an isolated index. When [copyFixture] points at a directory its
  /// contents are recursively copied into the temp project so the analyzer
  /// sees a real `pubspec.yaml` and resolvable imports.
  factory TestIndex.create({
    List<String> allowedPaths = const [],
    String? copyFixture,
  }) {
    final project = Directory.systemTemp.createTempSync('ci_proj_');
    final dataRoot = Directory.systemTemp.createTempSync('ci_data_');
    if (copyFixture != null) {
      _copyDir(Directory(copyFixture), project);
    }
    final dbPath = p.join(dataRoot.path, 'code_index.db');
    final db = initializeDatabase(dbPath);
    return TestIndex._(project, dataRoot, dbPath, db, allowedPaths);
  }

  void _wire() {
    write = WriteOperations(
      database: db,
      workingDir: project,
      allowedPaths: allowedPaths,
    );
    scan = ScanOperations(
      database: db,
      workingDir: project,
      dbPath: dbPath,
      allowedPaths: allowedPaths,
      onDatabaseReplaced: (newDb) {
        db = newDb;
        _wire();
      },
    );
    browse = BrowseOperations(
      database: db,
      workingDir: project,
      dbPath: dbPath,
      allowedPaths: allowedPaths,
    );
    search = SearchOperations(
      database: db,
      workingDir: project,
      allowedPaths: allowedPaths,
    );
    symbols = SymbolQueries(
      database: db,
      workingDir: project,
      allowedPaths: allowedPaths,
    );
    graph = GraphQueries(database: db, workingDir: project);
  }

  /// Write [contents] to `project/relPath`, creating parent directories.
  File writeFile(String relPath, String contents) {
    final f = File(p.join(project.path, relPath));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(contents);
    return f;
  }

  /// Resolve a project-relative path to its on-disk [File].
  File file(String relPath) => File(p.join(project.path, relPath));

  /// Re-point the allow-list and re-wire every handler. The project path is
  /// only known after [create], so scope tests seed files first, then call
  /// this with an allow-list under [project].
  void restrict(List<String> paths) {
    allowedPaths = paths;
    _wire();
  }

  /// `dart pub get` inside the temp project (required before the analyzer can
  /// resolve `package:` imports for Dart extraction).
  Future<void> pubGet() async {
    final r = await Process.run('dart', [
      'pub',
      'get',
    ], workingDirectory: project.path);
    if (r.exitCode != 0) {
      throw StateError('pub get failed: ${r.stderr}');
    }
  }

  /// Convenience wrapper over [WriteOperations.indexFiles].
  Future<Map<String, dynamic>> indexFiles(
    List<Map<String, dynamic>> files, {
    bool refreshDependents = false,
  }) async => jsonOf(
    await write.indexFiles({
      'files': files,
      'refresh_dependents': refreshDependents,
    }),
  );

  /// Convenience wrapper over [ScanOperations.scan] (defaults to `['.']`).
  Map<String, dynamic> scanDirs([Map<String, dynamic>? args]) => jsonOf(
    scan.scan(
      args ??
          {
            'directories': ['.'],
          },
    ),
  );

  void dispose() {
    try {
      db.dispose();
    } catch (_) {}
    if (project.existsSync()) project.deleteSync(recursive: true);
    if (dataRoot.existsSync()) dataRoot.deleteSync(recursive: true);
  }

  static void _copyDir(Directory src, Directory dst) {
    for (final entity in src.listSync(recursive: true)) {
      final rel = p.relative(entity.path, from: src.path);
      if (entity is File) {
        final dest = File(p.join(dst.path, rel));
        dest.parent.createSync(recursive: true);
        entity.copySync(dest.path);
      }
    }
  }
}
