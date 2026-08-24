/// Full-text `search` and aggregate `stats` for the code-index MCP server
/// (design §7.5, §7.10). Symbol- and graph-scoped queries live in
/// `symbol_queries.dart` and `graph_queries.dart` to keep this file lean.
library;

import 'dart:convert';
import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'stale_detection.dart';

/// Handles `search` (FTS5 + AND filters + LIKE fallback) and `stats`.
class SearchOperations {
  final Database database;
  final Directory workingDir;
  final List<String> allowedPaths;
  late final StaleDetector _staleDetector;

  SearchOperations({
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

  /// `search`: FTS5 across all indexed columns (OR + prefix + BM25) plus AND
  /// filters. Falls back to a LIKE scan when the FTS query is malformed.
  CallToolResult search(Map<String, dynamic>? args) {
    final query = args?['query'] as String?;
    final fileType = args?['file_type'] as String?;
    final language = args?['language'] as String?;
    final pathPattern = args?['path_pattern'] as String?;
    final tag = args?['tag'] as String?;
    final symbolName = args?['symbol_name'] as String?;
    final symbolKind = args?['symbol_kind'] as String?;
    final importPattern = args?['import_pattern'] as String?;
    final limit = args?['limit'] as int? ?? 25;

    if (pathPattern != null && pathPattern.isNotEmpty) {
      if (_checkAllowed(pathPattern) case final error?) return error;
    }

    final joins = <String>{};
    final conditions = <String>[];
    final values = <Object?>[];
    final filters = <String, dynamic>{};
    var useFts = false;

    if (query != null && query.isNotEmpty) {
      joins.add('JOIN code_index_fts fts ON fts.file_id = f.id');
      conditions.add('code_index_fts MATCH ?');
      values.add(_buildFtsQuery(query));
      useFts = true;
      filters['query'] = query;
    }

    void addFilter(String? v, String key, String clause, Object value) {
      if (v == null || v.isEmpty) return;
      conditions.add(clause);
      values.add(value);
      filters[key] = v;
    }

    addFilter(fileType, 'file_type', 'f.file_type = ?', fileType ?? '');
    addFilter(language, 'language', 'f.language = ?', language ?? '');
    addFilter(pathPattern, 'path_pattern', 'f.path LIKE ?', '%$pathPattern%');
    addFilter(tag, 'tag', 'f.tags LIKE ?', '%"$tag"%');

    if (symbolName != null && symbolName.isNotEmpty) {
      joins.add('JOIN symbols sy ON sy.file_id = f.id');
      conditions.add('sy.name = ?');
      values.add(symbolName);
      filters['symbol_name'] = symbolName;
    }
    if (symbolKind != null && symbolKind.isNotEmpty) {
      joins.add('JOIN symbols sy ON sy.file_id = f.id');
      conditions.add('sy.kind = ?');
      values.add(symbolKind);
      filters['symbol_kind'] = symbolKind;
    }
    if (importPattern != null && importPattern.isNotEmpty) {
      joins.add('JOIN imports im ON im.file_id = f.id');
      conditions.add('im.import_path LIKE ?');
      values.add('%$importPattern%');
      filters['import_pattern'] = importPattern;
    }

    final joinClause = joins.join('\n');
    final whereClause = conditions.isEmpty
        ? ''
        : 'WHERE ${conditions.join(' AND ')}';
    final orderClause = useFts ? 'ORDER BY rank' : 'ORDER BY f.path';

    final sql =
        '''
      SELECT DISTINCT f.id, f.path, f.summary, f.tags, f.file_type, f.language
      FROM files f
      $joinClause
      $whereClause
      $orderClause
      LIMIT ?
    ''';

    ResultSet result;
    try {
      result = database.select(sql, [...values, limit]);
    } on SqliteException {
      return _fallbackLikeSearch(query ?? '', filters, limit);
    }

    return _buildResults(result, filters);
  }

  /// OR-joined prefix tokens (BM25-ranked). `add task` → `"add"* OR "task"*`.
  String _buildFtsQuery(String query) {
    return query
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '"${t.replaceAll('"', '""')}"*')
        .join(' OR ');
  }

  CallToolResult _fallbackLikeSearch(
    String query,
    Map<String, dynamic> filters,
    int limit,
  ) {
    final like = '%$query%';
    final result = database.select(
      '''
      SELECT DISTINCT f.id, f.path, f.summary, f.tags, f.file_type, f.language
      FROM files f
      LEFT JOIN symbols sy ON sy.file_id = f.id
      LEFT JOIN symbol_references r ON r.file_id = f.id
      WHERE f.name LIKE ? OR f.summary LIKE ? OR f.path LIKE ?
        OR f.tags LIKE ? OR sy.name LIKE ? OR r.dot_path LIKE ?
      ORDER BY f.path
      LIMIT ?
    ''',
      [like, like, like, like, like, like, limit],
    );
    filters['fallback'] = 'like';
    return _buildResults(result, filters);
  }

  CallToolResult _buildResults(ResultSet result, Map<String, dynamic> filters) {
    final files = <Map<String, dynamic>>[];
    final filePaths = <String>[];
    for (final row in result) {
      final fileId = row['id'] as String;
      final filePath = row['path'] as String;
      filePaths.add(filePath);

      final symbols = database.select(
        "SELECT name FROM symbols WHERE file_id = ? AND visibility = 'public' "
        'ORDER BY name',
        [fileId],
      );

      files.add({
        'path': filePath,
        'summary': row['summary'],
        'tags': _decodeTags(row['tags'] as String?),
        'file_type': row['file_type'],
        'language': row['language'],
        'symbols': symbols.map((s) => s['name'] as String).toList(),
      });
    }

    final needsReindex = _staleDetector.checkPaths(filePaths);

    return jsonResult({
      'files': files,
      'count': files.length,
      'filters': filters,
      'needs_reindex': needsReindex,
    });
  }

  /// `stats`: aggregate counts, tag cloud, and freshness (design §7.10). No
  /// hash checks — counts only.
  CallToolResult stats(Map<String, dynamic>? args) {
    final topN = args?['limit'] as int? ?? 10;

    int count(String table) =>
        database.select('SELECT COUNT(*) AS c FROM $table').first['c'] as int;

    Map<String, int> group(String sql, String keyCol) => {
      for (final r in database.select(sql))
        (r[keyCol] as String? ?? 'unknown'): r['cnt'] as int,
    };

    final totalLines =
        database.select('SELECT SUM(line_count) AS s FROM files').first['s']
            as int? ??
        0;
    final totalWords =
        database.select('SELECT SUM(word_count) AS s FROM files').first['s']
            as int? ??
        0;

    final topImports = database.select(
      'SELECT import_path, COUNT(*) AS cnt FROM imports '
      'GROUP BY import_path ORDER BY cnt DESC LIMIT ?',
      [topN],
    );
    final topRefs = database.select(
      'SELECT dot_path, SUM(count) AS cnt FROM symbol_references '
      'GROUP BY dot_path ORDER BY cnt DESC LIMIT ?',
      [topN],
    );

    return jsonResult({
      'files': {
        'total': count('files'),
        'by_language': group(
          'SELECT language, COUNT(*) AS cnt FROM files '
              'GROUP BY language ORDER BY cnt DESC',
          'language',
        ),
        'by_type': group(
          'SELECT file_type, COUNT(*) AS cnt FROM files '
              'GROUP BY file_type ORDER BY cnt DESC',
          'file_type',
        ),
      },
      'symbols': {
        'total': count('symbols'),
        'by_kind': group(
          'SELECT kind, COUNT(*) AS cnt FROM symbols '
              'GROUP BY kind ORDER BY cnt DESC',
          'kind',
        ),
      },
      'imports': {
        'total': count('imports'),
        'top': topImports
            .map((r) => {'path': r['import_path'], 'count': r['cnt']})
            .toList(),
      },
      'references': {
        'total': count('symbol_references'),
        'top': topRefs
            .map((r) => {'dot_path': r['dot_path'], 'count': r['cnt']})
            .toList(),
      },
      'annotations': {
        'total': count('annotations'),
        'by_kind': group(
          'SELECT kind, COUNT(*) AS cnt FROM annotations '
              'GROUP BY kind ORDER BY cnt DESC',
          'kind',
        ),
      },
      'tags': _topTags(20),
      'freshness': group(
        'SELECT analysis_status, COUNT(*) AS cnt FROM files '
            'GROUP BY analysis_status',
        'analysis_status',
      ),
      'totals': {'lines': totalLines, 'words': totalWords},
    });
  }

  /// Flatten JSON `files.tags` arrays and return the top [n] by frequency.
  List<Map<String, dynamic>> _topTags(int n) {
    final counts = <String, int>{};
    for (final row in database.select('SELECT tags FROM files')) {
      for (final t in _decodeTags(row['tags'] as String?)) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(n).map((e) => {'tag': e.key, 'count': e.value}).toList();
  }

  List<String> _decodeTags(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => e.toString())
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
