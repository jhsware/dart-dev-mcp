import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart';

import 'scan_helpers.dart';

/// Diff operations handler for the code-index MCP server.
class DiffOperations {
  final Database database;
  final Directory workingDir;
  final List<String> allowedPaths;

  DiffOperations({required this.database, required this.workingDir, this.allowedPaths = const []});

  /// Scan directories and report changed/added/deleted files compared to the index.
  CallToolResult diff(Map<String, dynamic>? args) {
    final directories = args?['directories'] as List<dynamic>? ?? ['.'];
    final fileExtensions = args?['file_extensions'] as List<dynamic>?;
    final removeDeleted = args?['remove_deleted'] as bool? ?? true;

    if (directories.isEmpty) {
      return validationError('directories', 'directories must not be empty');
    }

    final extensionSet = fileExtensions
        ?.map((e) => (e as String).toLowerCase())
        .toSet();

    final scan = scanDisk(
      workingDir: workingDir,
      directories: directories,
      allowedPaths: allowedPaths,
      extensionFilter: extensionSet,
    );

    final indexedFiles = queryIndexedFiles(database, directories);

    final diff = compareDiskToIndex(scan: scan, indexedFiles: indexedFiles);

    // Remove deleted files from index if requested
    if (removeDeleted && diff.deleted.isNotEmpty) {
      withRetryTransactionSync(database, () {
        for (final path in diff.deleted) {
          // Delete FTS entry before deleting the file (FTS doesn't cascade)
          database.execute(
            'DELETE FROM code_search_fts WHERE file_id = (SELECT id FROM files WHERE path = ?)',
            [path],
          );
          database.execute('DELETE FROM files WHERE path = ?', [path]);
        }
      });
    }

    final responseData = <String, dynamic>{
      'changed': diff.changed,
      'added': diff.added,
      'deleted': diff.deleted,
      'summary': {
        'changed_count': diff.changed.length,
        'added_count': diff.added.length,
        'deleted_count': diff.deleted.length,
        'unchanged_count': diff.unchangedCount,
        'total_scanned': scan.diskFiles.length,
      },
    };

    if (diff.outOfScope.isNotEmpty) {
      responseData['out_of_scope'] = diff.outOfScope;
    }

    return jsonResult(responseData);
  }
}
