import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'database.dart';
import 'scan_helpers.dart';

/// Number of files indexed per `index-files` batch when estimating batches.
const int _batchSize = 8;

/// Scan operations handler for the code-index MCP server.
///
/// `scan` merges v1's `auto-scan` + `diff`: it walks the tree with the
/// mtime+size short-circuit, classifies added/changed/deleted files, removes
/// deleted rows, and emits a language-aware indexing plan for the agent
/// (design §7.1). It does not call an LLM itself.
class ScanOperations {
  Database _db;
  final Directory workingDir;
  final List<String> allowedPaths;
  final String dbPath;

  /// Callback that replaces [_db] after a rebuild so the connection cache
  /// stays in sync.
  final void Function(Database newDb)? onDatabaseReplaced;

  ScanOperations({
    required Database database,
    required this.workingDir,
    required this.dbPath,
    this.allowedPaths = const [],
    this.onDatabaseReplaced,
  }) : _db = database;

  /// Walk directories, detect changes, and produce an indexing plan.
  CallToolResult scan(Map<String, dynamic>? args) {
    final directories = args?['directories'] as List<dynamic>? ?? ['.'];
    final extensions = args?['extensions'] as List<dynamic>?;
    final sinceStr = args?['since'] as String?;
    final rebuild = args?['rebuild'] as bool? ?? false;
    final removeDeleted = args?['remove_deleted'] as bool? ?? true;
    final verify = args?['verify'] as bool? ?? false;

    if (directories.isEmpty) {
      return validationError('directories', 'directories must not be empty');
    }

    // Parse `since` as an ISO 8601 timestamp (mtime pre-filter).
    DateTime? since;
    if (sinceStr != null) {
      final parsed = DateTime.tryParse(sinceStr);
      if (parsed == null) {
        return validationError(
          'since',
          'since must be a valid ISO 8601 timestamp',
        );
      }
      since = parsed.toUtc();
    }

    // Full rebuild: drop and recreate the DB at the current schema version.
    if (rebuild) {
      final newDb = rebuildDatabase(dbPath, existingDb: _db);
      _db = newDb;
      onDatabaseReplaced?.call(newDb);
      // After a rebuild there are no indexed files, so `since` is irrelevant
      // and every file must return as `added`.
      since = null;
    }

    final extensionSet = extensions
        ?.map((e) => (e as String).toLowerCase())
        .toSet();

    final indexedFiles = queryIndexedFiles(_db, directories);

    final scanResult = scanDisk(
      workingDir: workingDir,
      directories: directories,
      allowedPaths: allowedPaths,
      indexedFiles: indexedFiles,
      extensionFilter: extensionSet,
      since: since,
      verify: verify,
    );

    final diff = compareDiskToIndex(
      scan: scanResult,
      indexedFiles: indexedFiles,
    );

    // Remove deleted files from the index if requested. Child rows cascade
    // via foreign keys; the FTS row must be deleted explicitly.
    if (removeDeleted && diff.deleted.isNotEmpty) {
      withRetryTransactionSync(_db, () {
        for (final path in diff.deleted) {
          _db.execute(
            'DELETE FROM code_index_fts WHERE file_id = '
            '(SELECT id FROM files WHERE path = ?)',
            [path],
          );
          _db.execute('DELETE FROM files WHERE path = ?', [path]);
        }
      });
    }

    // Touched-but-identical files were hashed because their stat changed —
    // e.g. a fresh worktree checkout resets every mtime — but their digest
    // is unchanged. Refresh the stored mtime+size so the next scan
    // short-circuits on stat instead of re-hashing the whole tree again.
    final touchedIdentical = scanResult.hashedFiles.entries
        .where((e) => indexedFiles[e.key]?.hash == e.value)
        .map((e) => e.key)
        .toList();
    if (touchedIdentical.isNotEmpty) {
      withRetryTransactionSync(_db, () {
        for (final path in touchedIdentical) {
          final stat = File(p.join(workingDir.path, path)).statSync();
          _db.execute(
            'UPDATE files SET mtime = ?, size_bytes = ? WHERE path = ?',
            [stat.modified.toUtc().toIso8601String(), stat.size, path],
          );
        }
      });
    }

    // Build the language-aware plan: one entry per added or changed file.
    final plan = <Map<String, dynamic>>[];
    for (final path in [...diff.added, ...diff.changed]) {
      plan.add({'path': path, 'needs': needsFor(path)});
    }
    plan.sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));

    final filesToIndex = plan.length;
    final estimatedBatches = (filesToIndex + _batchSize - 1) ~/ _batchSize;

    return jsonResult({
      'added': diff.added,
      'changed': diff.changed,
      'deleted': diff.deleted,
      'unchanged_count': diff.unchangedCount,
      'skipped_by_since': diff.skippedBySince,
      'out_of_scope': diff.outOfScope,
      'plan': plan,
      'summary': {
        'files_to_index': filesToIndex,
        'estimated_batches': estimatedBatches,
      },
    });
  }
}
