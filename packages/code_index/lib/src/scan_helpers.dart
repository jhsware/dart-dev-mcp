import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'hash_utils.dart';

/// Result of walking the filesystem and collecting file hashes.
class ScanResult {
  /// Relative path → file hash for files that passed all filters.
  final Map<String, String> diskFiles;

  /// Relative paths of files skipped because they are outside allowed paths.
  final List<String> outOfScope;

  /// Count of files skipped because their mtime was older than [since].
  final int skippedBySince;

  ScanResult({
    required this.diskFiles,
    required this.outOfScope,
    this.skippedBySince = 0,
  });
}

/// Result of comparing disk files against the index.
class DiffResult {
  final List<String> added;
  final List<String> changed;
  final List<String> deleted;
  final List<String> outOfScope;
  final int unchangedCount;
  final int skippedBySince;

  DiffResult({
    required this.added,
    required this.changed,
    required this.deleted,
    required this.outOfScope,
    required this.unchangedCount,
    this.skippedBySince = 0,
  });
}

/// Walk directories, filter files, and collect hashes.
///
/// If [since] is provided, files with mtime before [since] are skipped
/// without hashing — they are counted in [ScanResult.skippedBySince].
ScanResult scanDisk({
  required Directory workingDir,
  required List<dynamic> directories,
  required List<String> allowedPaths,
  Set<String>? extensionFilter,
  DateTime? since,
}) {
  final diskFiles = <String, String>{};
  final outOfScope = <String>[];
  var skippedBySince = 0;

  for (final dir in directories) {
    final dirPath = dir as String;
    final absDir = Directory(p.join(workingDir.path, dirPath));
    if (!absDir.existsSync()) continue;

    for (final entity in absDir.listSync(recursive: true)) {
      if (entity is! File) continue;

      final relativePath = p.relative(entity.path, from: workingDir.path);

      // Skip hidden files/dirs
      if (isHiddenPath(relativePath)) continue;

      // Filter by allowed paths if specified
      if (allowedPaths.isNotEmpty) {
        if (!isAllowedPath(allowedPaths, entity.path)) {
          outOfScope.add(relativePath);
          continue;
        }
      }

      // Filter by extension if specified
      if (extensionFilter != null) {
        final ext = p.extension(entity.path).toLowerCase();
        if (!extensionFilter.contains(ext)) continue;
      }

      // Skip files older than `since` without hashing
      if (since != null) {
        final stat = entity.statSync();
        if (stat.modified.isBefore(since)) {
          skippedBySince++;
          continue;
        }
      }

      final hash = computeFileHash(entity);
      diskFiles[relativePath] = hash;
    }
  }

  return ScanResult(
    diskFiles: diskFiles,
    outOfScope: outOfScope,
    skippedBySince: skippedBySince,
  );
}

/// Query the index for stored file hashes in the given directories.
Map<String, String> queryIndexedFiles(
  Database database,
  List<dynamic> directories,
) {
  final dirPatterns = directories.map((d) => '$d%').toList();
  final placeholders = dirPatterns.map((_) => 'path LIKE ?').join(' OR ');
  final indexedFiles = <String, String>{};

  final result = database.select(
    'SELECT path, file_hash FROM files WHERE $placeholders',
    dirPatterns,
  );
  for (final row in result) {
    indexedFiles[row['path'] as String] = row['file_hash'] as String;
  }

  return indexedFiles;
}

/// Compare disk files against indexed files and classify into
/// added, changed, deleted, and unchanged.
DiffResult compareDiskToIndex({
  required ScanResult scan,
  required Map<String, String> indexedFiles,
}) {
  final changed = <String>[];
  final added = <String>[];
  final deleted = <String>[];
  var unchangedCount = 0;

  for (final entry in scan.diskFiles.entries) {
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
    if (!scan.diskFiles.containsKey(path)) {
      deleted.add(path);
    }
  }

  changed.sort();
  added.sort();
  deleted.sort();
  final outOfScope = scan.outOfScope..sort();

  return DiffResult(
    added: added,
    changed: changed,
    deleted: deleted,
    outOfScope: outOfScope,
    unchangedCount: unchangedCount,
    skippedBySince: scan.skippedBySince,
  );
}
