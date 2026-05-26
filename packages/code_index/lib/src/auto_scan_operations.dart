import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database.dart';
import 'scan_helpers.dart';

/// Auto-scan operations handler for the code-index MCP server.
///
/// Produces a plan describing which files need (re-)indexing, without
/// calling an LLM itself. The caller (agent) consumes the plan and
/// drives the actual indexing via batched `auto-index` calls.
class AutoScanOperations {
  Database _db;
  final Directory workingDir;
  final List<String> allowedPaths;
  final String dbPath;

  /// Callback that replaces [_db] after a rebuild.
  /// The MCP server must supply this so the connection cache stays in sync.
  final void Function(Database newDb)? onDatabaseReplaced;

  AutoScanOperations({
    required Database database,
    required this.workingDir,
    required this.dbPath,
    this.allowedPaths = const [],
    this.onDatabaseReplaced,
  }) : _db = database;

  /// Scan directories and produce a plan for the agent.
  CallToolResult autoScan(Map<String, dynamic>? args) {
    final directories = args?['directories'] as List<dynamic>? ?? ['.'];
    final fileExtensions = args?['file_extensions'] as List<dynamic>?;
    final sinceStr = args?['since'] as String?;
    final rebuild = args?['rebuild'] as bool? ?? false;
    final layers = (args?['layers'] as List<dynamic>?)
            ?.map((e) => e as int)
            .toList() ??
        [0, 1, 2, 3];
    final removeDeleted = args?['remove_deleted'] as bool? ?? true;

    if (directories.isEmpty) {
      return validationError('directories', 'directories must not be empty');
    }

    // Parse since as ISO 8601 UTC
    DateTime? since;
    if (sinceStr != null) {
      since = DateTime.tryParse(sinceStr);
      if (since == null) {
        return validationError(
            'since', 'since must be a valid ISO 8601 timestamp');
      }
      since = since.toUtc();
    }

    // Full rebuild: drop and recreate the database
    if (rebuild) {
      final newDb = rebuildDatabase(dbPath, existingDb: _db);
      _db = newDb;
      onDatabaseReplaced?.call(newDb);
      // After rebuild there are no indexed files, so since is irrelevant
      since = null;
    }

    final extensionSet = fileExtensions
        ?.map((e) => (e as String).toLowerCase())
        .toSet();

    final scan = scanDisk(
      workingDir: workingDir,
      directories: directories,
      allowedPaths: allowedPaths,
      extensionFilter: extensionSet,
      since: since,
    );

    final indexedFiles = queryIndexedFiles(_db, directories);

    final diff = compareDiskToIndex(scan: scan, indexedFiles: indexedFiles);

    // Remove deleted files from index if requested
    if (removeDeleted && diff.deleted.isNotEmpty) {
      withRetryTransactionSync(_db, () {
        for (final path in diff.deleted) {
          _db.execute(
            'DELETE FROM code_search_fts WHERE file_id = (SELECT id FROM files WHERE path = ?)',
            [path],
          );
          _db.execute('DELETE FROM files WHERE path = ?', [path]);
        }
      });
    }

    // Build the plan: one entry per added or changed file
    final plan = <Map<String, dynamic>>[];
    for (final path in diff.added) {
      plan.add({'path': path, 'needs': layers});
    }
    for (final path in diff.changed) {
      plan.add({'path': path, 'needs': layers});
    }
    plan.sort((a, b) =>
        (a['path'] as String).compareTo(b['path'] as String));

    final filesToAnalyze = plan.length;
    final estimatedHaikuCalls = filesToAnalyze;

    final responseData = <String, dynamic>{
      'added': diff.added,
      'changed': diff.changed,
      'deleted': diff.deleted,
      'out_of_scope': diff.outOfScope,
      'plan': plan,
      'summary': {
        'files_to_analyze': filesToAnalyze,
        'estimated_haiku_calls': estimatedHaikuCalls,
        'skipped_by_since': diff.skippedBySince,
      },
    };

    return jsonResult(responseData);
  }
}
