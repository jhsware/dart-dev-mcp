/// Import-graph and annotation queries for the code-index MCP server
/// (design §7.8, §7.9): `dependents`, `dependencies`, and `annotations`.
library;

import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'stale_detection.dart';

/// Handles `dependents`, `dependencies`, and `annotations`.
class GraphQueries {
  final Database database;
  final Directory workingDir;
  final List<String> allowedPaths;
  late final StaleDetector _staleDetector;

  GraphQueries({
    required this.database,
    required this.workingDir,
    this.allowedPaths = const [],
  }) {
    _staleDetector = StaleDetector(database: database, workingDir: workingDir);
  }

  CallToolResult? _checkAllowed(String relativePath) {
    if (allowedPaths.isEmpty) return null;
    final absolutePath = p.normalize(p.join(workingDir.path, relativePath));
    if (isAllowedPath(allowedPaths, absolutePath)) return null;
    return outOfScopeResponse(
      path: relativePath,
      allowedPaths: getAllowedRelativePaths(workingDir, allowedPaths),
    );
  }

  /// `dependents(path)`: files whose imports reference [path] by suffix match,
  /// with the matching imports and their public symbols (design §7.8).
  CallToolResult dependents(Map<String, dynamic>? args) {
    final importPath = args?['path'] as String?;
    if (requireString(importPath, 'path') case final error?) return error;
    if (_checkAllowed(importPath!) case final error?) return error;

    final result = database.select('''
      SELECT DISTINCT f.id, f.path, f.summary, f.file_type
      FROM files f
      JOIN imports i ON i.file_id = f.id
      WHERE i.import_path LIKE ?
      ORDER BY f.path
    ''', ['%$importPath%']);

    final files = <Map<String, dynamic>>[];
    final filePaths = <String>[];
    for (final row in result) {
      final fileId = row['id'] as String;
      final filePath = row['path'] as String;
      filePaths.add(filePath);

      final matching = database.select(
        'SELECT import_path FROM imports WHERE file_id = ? AND import_path LIKE ?',
        [fileId, '%$importPath%'],
      );
      final symbols = database.select(
        "SELECT name FROM symbols WHERE file_id = ? AND visibility = 'public' "
        'ORDER BY name',
        [fileId],
      );

      files.add({
        'path': filePath,
        'summary': row['summary'],
        'file_type': row['file_type'],
        'matching_imports':
            matching.map((i) => i['import_path'] as String).toList(),
        'symbols': symbols.map((s) => s['name'] as String).toList(),
      });
    }

    final needsReindex = _staleDetector.checkPaths(filePaths);

    return jsonResult({
      'dependents': files,
      'count': files.length,
      'import_path_query': importPath,
      'needs_reindex': needsReindex,
    });
  }

  /// `dependencies(path)`: the file's imports, each classified `internal`
  /// (resolves to an indexed file) or `external` (design §7.8).
  CallToolResult dependencies(Map<String, dynamic>? args) {
    final path = args?['path'] as String?;
    if (requireString(path, 'path') case final error?) return error;
    if (_checkAllowed(path!) case final error?) return error;

    final fileResult = database.select(
      'SELECT id, path, summary, file_type FROM files WHERE path = ?',
      [path],
    );
    if (fileResult.isEmpty) return notFoundError('File', path);

    final file = fileResult.first;
    final fileId = file['id'] as String;

    final imports = database.select(
      'SELECT import_path FROM imports WHERE file_id = ? ORDER BY import_path',
      [fileId],
    );

    final deps = <Map<String, dynamic>>[];
    for (final imp in imports) {
      final importPath = imp['import_path'] as String;
      final indexed = database.select(
        'SELECT path, summary, file_type FROM files '
        'WHERE path = ? OR path LIKE ? LIMIT 1',
        [importPath, '%$importPath'],
      );

      if (indexed.isNotEmpty) {
        final f = indexed.first;
        deps.add({
          'import_path': importPath,
          'classification': 'internal',
          'resolved_path': f['path'],
          'summary': f['summary'],
          'file_type': f['file_type'],
        });
      } else {
        deps.add({
          'import_path': importPath,
          'classification': 'external',
        });
      }
    }

    final internal =
        deps.where((d) => d['classification'] == 'internal').length;
    final external = deps.length - internal;

    final needsReindex = _staleDetector.checkPaths([path]);

    return jsonResult({
      'file': {
        'path': file['path'],
        'summary': file['summary'],
        'file_type': file['file_type'],
      },
      'dependencies': deps,
      'count': deps.length,
      'internal_count': internal,
      'external_count': external,
      'needs_reindex': needsReindex,
    });
  }

  /// `annotations`: TODO/FIXME/HACK/NOTE/DEPRECATED queries with `by_kind`
  /// counts (design §7.9).
  CallToolResult annotations(Map<String, dynamic>? args) {
    final kind = args?['kind'] as String?;
    final messagePattern = args?['message_pattern'] as String?;
    final pathPattern = args?['path_pattern'] as String?;
    final fileType = args?['file_type'] as String?;
    final limit = args?['limit'] as int? ?? 100;

    if (pathPattern != null && pathPattern.isNotEmpty) {
      if (_checkAllowed(pathPattern) case final error?) return error;
    }

    final conditions = <String>[];
    final values = <Object?>[];
    final filters = <String, dynamic>{};

    if (kind != null && kind.isNotEmpty) {
      conditions.add('a.kind = ?');
      values.add(kind);
      filters['kind'] = kind;
    }
    if (messagePattern != null && messagePattern.isNotEmpty) {
      conditions.add('a.message LIKE ?');
      values.add('%$messagePattern%');
      filters['message_pattern'] = messagePattern;
    }
    if (pathPattern != null && pathPattern.isNotEmpty) {
      conditions.add('f.path LIKE ?');
      values.add('%$pathPattern%');
      filters['path_pattern'] = pathPattern;
    }
    if (fileType != null && fileType.isNotEmpty) {
      conditions.add('f.file_type = ?');
      values.add(fileType);
      filters['file_type'] = fileType;
    }

    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final result = database.select('''
      SELECT a.kind, a.message, a.line, f.path, f.file_type
      FROM annotations a
      JOIN files f ON a.file_id = f.id
      $whereClause
      ORDER BY f.path, a.line
      LIMIT ?
    ''', [...values, limit]);

    final items = <Map<String, dynamic>>[];
    final filePaths = <String>{};
    final byKind = <String, int>{};
    for (final row in result) {
      filePaths.add(row['path'] as String);
      final k = row['kind'] as String;
      byKind[k] = (byKind[k] ?? 0) + 1;
      items.add({
        'kind': k,
        'message': row['message'],
        'line': row['line'],
        'path': row['path'],
        'file_type': row['file_type'],
      });
    }

    final needsReindex = _staleDetector.checkPaths(filePaths);

    return jsonResult({
      'annotations': items,
      'count': items.length,
      'by_kind': byKind,
      'filters': filters,
      'needs_reindex': needsReindex,
    });
  }
}
