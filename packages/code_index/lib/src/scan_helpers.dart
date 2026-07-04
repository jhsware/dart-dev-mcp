import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'hash_utils.dart';

/// Stored change-detection metadata for an indexed file (design §4.2).
class IndexedFileMeta {
  final String hash;
  final String? mtime;
  final int? size;

  IndexedFileMeta({required this.hash, this.mtime, this.size});
}

/// Result of walking the filesystem with the mtime+size short-circuit.
class ScanResult {
  /// Relative path → freshly-computed SHA-256 for files that were hashed
  /// (stat mismatch, missing from index, or [verify] mode).
  final Map<String, String> hashedFiles;

  /// Relative paths short-circuited as unchanged (mtime+size matched the
  /// stored values, so hashing was skipped).
  final Set<String> unchanged;

  /// Relative paths skipped because they are outside allowed paths.
  final List<String> outOfScope;

  /// Count of files skipped because their mtime was older than `since`.
  final int skippedBySince;

  ScanResult({
    required this.hashedFiles,
    required this.unchanged,
    required this.outOfScope,
    this.skippedBySince = 0,
  });

  /// Every relative path seen on disk (hashed + short-circuited).
  Iterable<String> get diskPaths => [...hashedFiles.keys, ...unchanged];
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

/// Walk directories, filter files, and apply the mtime+size short-circuit.
///
/// For each candidate file the stat is compared against the stored
/// [indexedFiles] metadata: when mtime **and** size match (and [verify] is
/// false) the file is treated as unchanged and hashing is skipped. Otherwise
/// the SHA-256 is computed. Files with mtime before [since] are skipped
/// without stat comparison and counted in [ScanResult.skippedBySince].
ScanResult scanDisk({
  required Directory workingDir,
  required List<dynamic> directories,
  required List<String> allowedPaths,
  required Map<String, IndexedFileMeta> indexedFiles,
  Set<String>? extensionFilter,
  DateTime? since,
  bool verify = false,
}) {
  final hashedFiles = <String, String>{};
  final unchanged = <String>{};
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

      final stat = entity.statSync();

      // Skip files older than `since` without hashing
      if (since != null && stat.modified.isBefore(since)) {
        skippedBySince++;
        continue;
      }

      // mtime+size short-circuit: skip hashing when the file is unchanged.
      final meta = indexedFiles[relativePath];
      if (!verify &&
          meta != null &&
          isUnchanged(
            storedMtimeIso: meta.mtime,
            storedSize: meta.size,
            stat: stat,
          )) {
        unchanged.add(relativePath);
        continue;
      }

      hashedFiles[relativePath] = computeFileHash(entity);
    }
  }

  return ScanResult(
    hashedFiles: hashedFiles,
    unchanged: unchanged,
    outOfScope: outOfScope,
    skippedBySince: skippedBySince,
  );
}

/// Query the index for stored change-detection metadata in the given
/// directories (path → hash/mtime/size).
Map<String, IndexedFileMeta> queryIndexedFiles(
  Database database,
  List<dynamic> directories,
) {
  final dirPatterns = directories
      .map((d) => (d == '.' || d == './') ? '%' : '$d%')
      .toList();
  final placeholders = dirPatterns.map((_) => 'path LIKE ?').join(' OR ');
  final indexedFiles = <String, IndexedFileMeta>{};

  final result = database.select(
    'SELECT path, file_hash, mtime, size_bytes FROM files WHERE $placeholders',
    dirPatterns,
  );
  for (final row in result) {
    indexedFiles[row['path'] as String] = IndexedFileMeta(
      hash: row['file_hash'] as String,
      mtime: row['mtime'] as String?,
      size: row['size_bytes'] as int?,
    );
  }

  return indexedFiles;
}

/// Compare a [scan] against stored [indexedFiles] and classify into
/// added / changed / deleted / unchanged.
///
/// Short-circuited files are always unchanged. Hashed files are `added`
/// when absent from the index, `changed` on digest mismatch, and unchanged
/// (touched-but-identical) when the digest still matches.
///
/// Short-circuited files are always unchanged. Hashed files are `added`
/// when absent from the index, `changed` on digest mismatch, and unchanged
/// (touched-but-identical) when the digest still matches.
DiffResult compareDiskToIndex({
  required ScanResult scan,
  required Map<String, IndexedFileMeta> indexedFiles,
}) {
  final added = <String>[];
  final changed = <String>[];
  final deleted = <String>[];
  var unchangedCount = scan.unchanged.length;

  for (final entry in scan.hashedFiles.entries) {
    final meta = indexedFiles[entry.key];
    if (meta == null) {
      added.add(entry.key);
    } else if (meta.hash != entry.value) {
      changed.add(entry.key);
    } else {
      unchangedCount++;
    }
  }

  final diskPaths = scan.diskPaths.toSet();
  for (final path in indexedFiles.keys) {
    if (!diskPaths.contains(path)) {
      deleted.add(path);
    }
  }

  added.sort();
  changed.sort();
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

/// The language / file-type for a path, derived from its extension
/// (lowercase, without the leading dot). Returns `null` when there is no
/// extension.
String? languageFor(String path) {
  final ext = p.extension(path).toLowerCase();
  return ext.isEmpty ? null : ext.substring(1);
}

/// Agent-produced layers wanted for a path, language-aware (design §7.1):
/// Dart files need `[1, 3]` (the MCP computes their layer 2), every other
/// file needs `[1, 2, 3]`.
List<int> needsFor(String path) {
  return languageFor(path) == 'dart' ? const [1, 3] : const [1, 2, 3];
}
