import 'dart:io';

import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:dart_dev_mcp/mcp_server/utils/sqlite_helpers.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'hash_utils.dart';

/// Diff operations handler for the code-index MCP server.
class DiffOperations {
  final Database database;
  final Directory workingDir;

  DiffOperations({required this.database, required this.workingDir});

  /// Scan directories and report changed/added/deleted files compared to the index.
  CallToolResult diff(Map<String, dynamic>? args) {
    final directories = args?['directories'] as List<dynamic>?;
    final fileExtensions = args?['file_extensions'] as List<dynamic>?;
    final removeDeleted = args?['remove_deleted'] as bool? ?? true;

    if (directories == null || directories.isEmpty) {
      return validationError('directories', 'directories is required');
    }

    final extensionSet = fileExtensions
        ?.map((e) => (e as String).toLowerCase())
        .toSet();

    // Collect all files on disk from the specified directories
    final diskFiles = <String, String>{}; // relative path -> hash

    for (final dir in directories) {
      final dirPath = dir as String;
      final absDir = Directory(p.join(workingDir.path, dirPath));
      if (!absDir.existsSync()) continue;

      for (final entity in absDir.listSync(recursive: true)) {
        if (entity is! File) continue;

        final relativePath =
            p.relative(entity.path, from: workingDir.path);

        // Skip hidden files/dirs
        if (isHiddenPath(relativePath)) continue;

        // Filter by extension if specified
        if (extensionSet != null) {
          final ext = p.extension(entity.path).toLowerCase();
          if (!extensionSet.contains(ext)) continue;
        }

        final hash = computeFileHash(entity);
        diskFiles[relativePath] = hash;
      }
    }

    // Get indexed files for the scanned directories
    final dirPatterns = directories.map((d) => '$d%').toList();
    final placeholders = dirPatterns.map((_) => 'path LIKE ?').join(' OR ');
    final indexedFiles = <String, String>{}; // relative path -> hash

    final result = database.select(
      'SELECT path, file_hash FROM files WHERE $placeholders',
      dirPatterns,
    );
    for (final row in result) {
      indexedFiles[row['path'] as String] = row['file_hash'] as String;
    }

    // Compare
    final changed = <String>[];
    final added = <String>[];
    final deleted = <String>[];
    var unchangedCount = 0;

    for (final entry in diskFiles.entries) {
      final indexedHash = indexedFiles[entry.key];
      if (indexedHash == null) {
        added.add(entry.key);
      } else if (indexedHash != entry.value) {
        changed.add(entry.key);
      } else {
        unchangedCount++;
      }
    }

    for (final path in indexedFiles.keys) {
      if (!diskFiles.containsKey(path)) {
        deleted.add(path);
      }
    }

    // Remove deleted files from index if requested
    if (removeDeleted && deleted.isNotEmpty) {
      withRetryTransactionSync(database, () {
        for (final path in deleted) {
          database.execute('DELETE FROM files WHERE path = ?', [path]);
        }
      });
    }

    changed.sort();
    added.sort();
    deleted.sort();

    return jsonResult({
      'changed': changed,
      'added': added,
      'deleted': deleted,
      'summary': {
        'changed_count': changed.length,
        'added_count': added.length,
        'deleted_count': deleted.length,
        'unchanged_count': unchangedCount,
        'total_scanned': diskFiles.length,
      },
    });
  }
}
