/// Dependent reference refresh (design §8.5.3).
///
/// When a Dart file changes, its direct project-internal importers may now
/// resolve differently even though their own content is unchanged. This
/// re-resolves those dependents against the warm analysis context and replaces
/// only their `symbol_references` rows + the FTS `reference_symbols` column —
/// no LLM tokens, summaries left intact.
library;

import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'dart_extractor.dart';

final _uuid = Uuid();

/// Re-resolves references of the direct Dart dependents of [changedRelPaths].
class ReferenceRefresh {
  final Database database;
  final Directory workingDir;
  final DartExtractor extractor;

  ReferenceRefresh({
    required this.database,
    required this.workingDir,
    required this.extractor,
  });

  /// Refresh dependents of the changed files, excluding any path already in
  /// [excludePaths] (the current batch). Returns the refreshed relative paths.
  Future<List<String>> refresh(
    Iterable<String> changedRelPaths, {
    Set<String> excludePaths = const {},
  }) async {
    final dependents = _findDependents(changedRelPaths, excludePaths);
    final refreshed = <String>[];
    for (final dep in dependents) {
      final ok = await _refreshOne(dep.$1, dep.$2);
      if (ok) refreshed.add(dep.$2);
    }
    return refreshed;
  }

  /// Direct internal Dart dependents as `(file_id, path)` tuples.
  List<(String, String)> _findDependents(
    Iterable<String> changedRelPaths,
    Set<String> excludePaths,
  ) {
    final seen = <String>{};
    final out = <(String, String)>[];
    for (final rel in changedRelPaths) {
      final libRel = rel.startsWith('lib/') ? rel.substring(4) : rel;
      final base = p.basename(rel);
      final rows = database.select(
        '''
        SELECT DISTINCT f.id AS id, f.path AS path
        FROM imports i
        JOIN files f ON f.id = i.file_id
        WHERE f.file_type = 'dart'
          AND (i.import_path LIKE ? OR i.import_path LIKE ?)
        ''',
        ['%$libRel', '%$base'],
      );
      for (final row in rows) {
        final path = row['path'] as String;
        if (path == rel ||
            excludePaths.contains(path) ||
            seen.contains(path)) {
          continue;
        }
        seen.add(path);
        out.add((row['id'] as String, path));
      }
    }
    return out;
  }

  /// Re-resolve one dependent and replace its references + FTS column.
  Future<bool> _refreshOne(String fileId, String relPath) async {
    final absPath = p.normalize(p.join(workingDir.path, relPath));
    if (!File(absPath).existsSync()) return false;

    await extractor.notifyChanged(absPath);
    final ExtractedFile extracted;
    try {
      extracted = await extractor.extractFile(absPath);
    } catch (_) {
      return false;
    }

    final now = DateTime.now().toUtc().toIso8601String();
    withRetryTransactionSync(database, () {
      database
          .execute('DELETE FROM symbol_references WHERE file_id = ?', [fileId]);
      for (final ref in extracted.references) {
        database.execute(
          '''
          INSERT OR IGNORE INTO symbol_references (id, file_id, symbol, module,
            source_path, dot_path, symbol_kind, resolution, count, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            _uuid.v4(), fileId, ref.symbol, ref.module, ref.sourcePath,
            ref.dotPath, ref.symbolKind, ref.resolution, ref.count, now,
          ],
        );
      }
      _replaceFtsReferences(
          database, fileId, extracted.references.map((r) => r.dotPath));
      database.execute(
        'UPDATE files SET structure_refreshed_at = ?, updated_at = ? WHERE id = ?',
        [now, now, fileId],
      );
    });
    return true;
  }
}

/// Rebuild the FTS `reference_symbols` column for [fileId], preserving every
/// other FTS column. FTS5 has no column-level update, so the row is replaced.
void _replaceFtsReferences(
  Database database,
  String fileId,
  Iterable<String> dotPaths,
) {
  final existing = database.select(
    '''
    SELECT path, name, summary, tags, symbol_names, symbol_summaries
    FROM code_index_fts WHERE file_id = ?
    ''',
    [fileId],
  );
  if (existing.isEmpty) return;
  final row = existing.first;
  database.execute('DELETE FROM code_index_fts WHERE file_id = ?', [fileId]);
  database.execute(
    '''
    INSERT INTO code_index_fts (file_id, path, name, summary, tags,
      symbol_names, symbol_summaries, reference_symbols)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    [
      fileId,
      row['path'],
      row['name'],
      row['summary'],
      row['tags'],
      row['symbol_names'],
      row['symbol_summaries'],
      dotPaths.join(' '),
    ],
  );
}
