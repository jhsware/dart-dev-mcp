import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'hash_utils.dart';

/// Detects stale index entries by comparing on-disk file hashes with stored
/// hashes, and checking whether requested layers are present.
class StaleDetector {
  final Database database;
  final Directory workingDir;

  StaleDetector({required this.database, required this.workingDir});

  /// Check on-disk hashes for the given relative paths.
  ///
  /// For each path where the on-disk hash differs from the stored hash,
  /// marks `analysis_status='stale'` in the DB and returns a
  /// `{ path, reason: 'changed' }` entry.
  ///
  /// Files that don't exist on disk are silently skipped (deletion is
  /// handled by the diff operation).
  List<Map<String, String>> checkPaths(Iterable<String> relPaths) {
    final results = <Map<String, String>>[];

    for (final relPath in relPaths) {
      final absolutePath = p.normalize(p.join(workingDir.path, relPath));
      final file = File(absolutePath);
      if (!file.existsSync()) continue;

      final rows = database.select(
        'SELECT file_hash, mtime, size_bytes, analysis_status '
        'FROM files WHERE path = ?',
        [relPath],
      );
      if (rows.isEmpty) continue;

      // mtime+size short-circuit: skip hashing when the file is unchanged.
      final stat = file.statSync();
      if (isUnchanged(
        storedMtimeIso: rows.first['mtime'] as String?,
        storedSize: rows.first['size_bytes'] as int?,
        stat: stat,
      )) {
        continue;
      }

      final storedHash = rows.first['file_hash'] as String?;
      final currentHash = computeFileHash(file);

      if (storedHash != currentHash) {
        // Mark stale in DB but don't modify row contents
        if (rows.first['analysis_status'] != 'stale') {
          database.execute(
            "UPDATE files SET analysis_status = 'stale' WHERE path = ?",
            [relPath],
          );
        }
        results.add({'path': relPath, 'reason': 'changed'});
      }
    }

    return results;
  }

  /// Check whether requested layers are present for the given paths.
  ///
  /// Returns `{ path, reason: 'missing_layer' }` for each file that lacks
  /// any of the requested layers in its `layers_present` column.
  List<Map<String, String>> checkLayers(
    Iterable<String> relPaths,
    List<int> layers,
  ) {
    final results = <Map<String, String>>[];

    for (final relPath in relPaths) {
      final rows = database.select(
        'SELECT layers_present FROM files WHERE path = ?',
        [relPath],
      );
      if (rows.isEmpty) continue;

      final layersJson = rows.first['layers_present'] as String?;
      final present = layersJson != null
          ? (jsonDecode(layersJson) as List<dynamic>).cast<int>().toSet()
          : <int>{};

      // Layer 4 is derived from layer 2 at read time — no storage needed
      final storedLayers =
          layers.where((l) => l != 4).toList();

      for (final layer in storedLayers) {
        if (!present.contains(layer)) {
          results.add({'path': relPath, 'reason': 'missing_layer'});
          break; // one entry per file is enough
        }
      }
    }

    return results;
  }

  /// Combines hash checks and layer checks, de-duplicated by path.
  ///
  /// A file that is both changed and missing layers appears only once
  /// with `reason: 'changed'` (the stronger signal).
  List<Map<String, String>> needsReindex(
    Iterable<String> relPaths,
    List<int> layers,
  ) {
    final pathList = relPaths.toList();
    final changed = checkPaths(pathList);
    final changedPaths = changed.map((e) => e['path']).toSet();

    final missingLayers = checkLayers(pathList, layers)
        .where((e) => !changedPaths.contains(e['path']))
        .toList();

    return [...changed, ...missingLayers];
  }
}
