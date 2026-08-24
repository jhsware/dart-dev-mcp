/// Symbol-scoped queries for the code-index MCP server (design §7.6, §7.7):
/// `find-symbol` (jump-to-definition → line range) and `references`
/// (dot-path reference lookups).
library;

import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'stale_detection.dart';

/// Handles `find-symbol` and `references`.
class SymbolQueries {
  final Database database;
  final Directory workingDir;
  final List<String> allowedPaths;
  late final StaleDetector _staleDetector;

  SymbolQueries({
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

  /// `find-symbol`: resolve a declaration to its file + line range — the
  /// jump-to-definition op that enables partial reads (design §7.6).
  ///
  /// Params: `name` (required), `match` (`exact`|`prefix`, default `exact`),
  /// `kind`, `visibility`, `path_pattern`, `limit` (default 25).
  CallToolResult findSymbol(Map<String, dynamic>? args) {
    final name = args?['name'] as String?;
    final match = (args?['match'] as String?) ?? 'exact';
    final kind = args?['kind'] as String?;
    final visibility = args?['visibility'] as String?;
    final pathPattern = args?['path_pattern'] as String?;
    final limit = args?['limit'] as int? ?? 25;

    if (requireString(name, 'name') case final error?) return error;
    if (match != 'exact' && match != 'prefix') {
      return validationError('match', "match must be 'exact' or 'prefix'");
    }
    if (pathPattern != null && pathPattern.isNotEmpty) {
      if (_checkAllowed(pathPattern) case final error?) return error;
    }

    final conditions = <String>['s.name ${match == 'prefix' ? 'LIKE' : '='} ?'];
    final values = <Object?>[match == 'prefix' ? '$name%' : name];

    if (kind != null && kind.isNotEmpty) {
      conditions.add('s.kind = ?');
      values.add(kind);
    }
    if (visibility != null && visibility.isNotEmpty) {
      conditions.add('s.visibility = ?');
      values.add(visibility);
    }
    if (pathPattern != null && pathPattern.isNotEmpty) {
      conditions.add('f.path LIKE ?');
      values.add('%$pathPattern%');
    }

    final result = database.select(
      '''
      SELECT f.path, s.name, s.kind, s.parent, s.visibility, s.signature,
             s.line, s.end_line, s.summary
      FROM symbols s
      JOIN files f ON s.file_id = f.id
      WHERE ${conditions.join(' AND ')}
      ORDER BY f.path, s.line
      LIMIT ?
    ''',
      [...values, limit],
    );

    final filePaths = <String>{};
    final matches = result.map((row) {
      filePaths.add(row['path'] as String);
      return {
        'path': row['path'],
        'name': row['name'],
        'kind': row['kind'],
        'parent': row['parent'],
        'visibility': row['visibility'],
        'signature': row['signature'],
        'line': row['line'],
        'end_line': row['end_line'],
        'summary': row['summary'],
      };
    }).toList();

    final needsReindex = _staleDetector.checkPaths(filePaths);

    return jsonResult({
      'matches': matches,
      'count': matches.length,
      'needs_reindex': needsReindex,
    });
  }

  /// `references`: which files use a symbol, in dot-path notation (design
  /// §7.7). Matches ordered by `count` descending.
  ///
  /// Params: `symbol` (exact), `module`, `source_path`, `dot_path_pattern`
  /// (LIKE), `kind`, `resolution` (`resolved`|`declared`), `path_pattern`,
  /// `limit` (default 25).
  CallToolResult references(Map<String, dynamic>? args) {
    final symbol = args?['symbol'] as String?;
    final module = args?['module'] as String?;
    final sourcePath = args?['source_path'] as String?;
    final dotPathPattern = args?['dot_path_pattern'] as String?;
    final kind = args?['kind'] as String?;
    final resolution = args?['resolution'] as String?;
    final pathPattern = args?['path_pattern'] as String?;
    final limit = args?['limit'] as int? ?? 25;

    if (pathPattern != null && pathPattern.isNotEmpty) {
      if (_checkAllowed(pathPattern) case final error?) return error;
    }

    final conditions = <String>[];
    final values = <Object?>[];

    void eq(String? v, String col) {
      if (v == null || v.isEmpty) return;
      conditions.add('r.$col = ?');
      values.add(v);
    }

    eq(symbol, 'symbol');
    eq(module, 'module');
    eq(sourcePath, 'source_path');
    eq(kind, 'symbol_kind');
    eq(resolution, 'resolution');
    if (dotPathPattern != null && dotPathPattern.isNotEmpty) {
      conditions.add('r.dot_path LIKE ?');
      values.add('%$dotPathPattern%');
    }
    if (pathPattern != null && pathPattern.isNotEmpty) {
      conditions.add('f.path LIKE ?');
      values.add('%$pathPattern%');
    }

    final whereClause = conditions.isEmpty
        ? ''
        : 'WHERE ${conditions.join(' AND ')}';

    final result = database.select(
      '''
      SELECT f.path, r.dot_path, r.symbol, r.module, r.source_path,
             r.symbol_kind, r.resolution, r.count
      FROM symbol_references r
      JOIN files f ON r.file_id = f.id
      $whereClause
      ORDER BY r.count DESC, f.path
      LIMIT ?
    ''',
      [...values, limit],
    );

    final filePaths = <String>{};
    final matches = result.map((row) {
      filePaths.add(row['path'] as String);
      return {
        'path': row['path'],
        'dot_path': row['dot_path'],
        'symbol': row['symbol'],
        'module': row['module'],
        'source_path': row['source_path'],
        'kind': row['symbol_kind'],
        'resolution': row['resolution'],
        'count': row['count'],
      };
    }).toList();

    final needsReindex = _staleDetector.checkPaths(filePaths);

    return jsonResult({
      'matches': matches,
      'count': matches.length,
      'needs_reindex': needsReindex,
    });
  }
}
