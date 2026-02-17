import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart';

/// Search operations handler for the code-index MCP server.
class SearchOperations {
  final Database database;

  SearchOperations({required this.database});

  /// Search the code index for files matching given criteria.
  ///
  /// Returns rich results including file metadata and exports summary.
  CallToolResult search(Map<String, dynamic>? args) {
    final query = args?['query'] as String?;
    final fileType = args?['file_type'] as String?;
    final namePattern = args?['name_pattern'] as String?;
    final exportName = args?['export_name'] as String?;
    final exportKind = args?['export_kind'] as String?;
    final importPattern = args?['import_pattern'] as String?;
    final pathPattern = args?['path_pattern'] as String?;
    final descriptionPattern = args?['description_pattern'] as String?;
    final limit = args?['limit'] as int? ?? 50;

    final joins = <String>{};
    final conditions = <String>[];
    final values = <Object?>[];
    final filters = <String, dynamic>{};
    var useFts = false;

    // General text search — use FTS5 for ranked results
    if (query != null && query.isNotEmpty) {
      // Escape FTS5 special characters and wrap each token with *
      final ftsQuery = _buildFtsQuery(query);
      joins.add('JOIN code_search_fts fts ON fts.file_id = f.id');
      conditions.add('code_search_fts MATCH ?');
      values.add(ftsQuery);
      useFts = true;
      filters['query'] = query;
    }

    // Exact file type filter
    if (fileType != null && fileType.isNotEmpty) {
      conditions.add('f.file_type = ?');
      values.add(fileType);
      filters['file_type'] = fileType;
    }

    // File name pattern
    if (namePattern != null && namePattern.isNotEmpty) {
      conditions.add('f.name LIKE ?');
      values.add('%$namePattern%');
      filters['name_pattern'] = namePattern;
    }

    // Export name search
    if (exportName != null && exportName.isNotEmpty) {
      joins.add('LEFT JOIN exports e ON e.file_id = f.id');
      conditions.add('e.name LIKE ?');
      values.add('%$exportName%');
      filters['export_name'] = exportName;
    }

    // Export kind filter
    if (exportKind != null && exportKind.isNotEmpty) {
      joins.add('LEFT JOIN exports e ON e.file_id = f.id');
      conditions.add('e.kind = ?');
      values.add(exportKind);
      filters['export_kind'] = exportKind;
    }

    // Import path search
    if (importPattern != null && importPattern.isNotEmpty) {
      joins.add('LEFT JOIN imports i ON i.file_id = f.id');
      conditions.add('i.import_path LIKE ?');
      values.add('%$importPattern%');
      filters['import_pattern'] = importPattern;
    }

    // File path pattern
    if (pathPattern != null && pathPattern.isNotEmpty) {
      conditions.add('f.path LIKE ?');
      values.add('%$pathPattern%');
      filters['path_pattern'] = pathPattern;
    }

    // Description pattern
    if (descriptionPattern != null && descriptionPattern.isNotEmpty) {
      conditions.add('f.description LIKE ?');
      values.add('%$descriptionPattern%');
      filters['description_pattern'] = descriptionPattern;
    }

    // Build the query — use BM25 ranking when FTS is active
    final joinClause = joins.join('\n');
    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final orderClause = useFts ? 'ORDER BY fts.rank' : 'ORDER BY f.path';

    final sql = '''
      SELECT DISTINCT f.id, f.path, f.name, f.description, f.file_type
      FROM files f
      $joinClause
      $whereClause
      $orderClause
      LIMIT ?
    ''';
    values.add(limit);

    ResultSet result;
    try {
      result = database.select(sql, values);
    } on SqliteException {
      // FTS syntax error — fall back to LIKE search
      return _fallbackLikeSearch(query!, filters, limit);
    }

    return _buildRichResults(result, filters);
  }

  /// Build FTS5 query string from user input.
  ///
  /// Escapes special FTS5 characters and adds prefix matching (*).
  String _buildFtsQuery(String query) {
    // Split on whitespace, escape each token, add prefix wildcard
    final tokens = query.split(RegExp(r'\s+'));
    final escaped = tokens
        .where((t) => t.isNotEmpty)
        .map((t) {
          // Escape double quotes in the token
          final safe = t.replaceAll('"', '""');
          // Wrap in quotes for safety, add * for prefix matching
          return '"$safe"*';
        })
        .join(' OR ');
    return escaped;
  }

  /// Fallback LIKE-based search when FTS query fails.
  CallToolResult _fallbackLikeSearch(
    String query,
    Map<String, dynamic> filters,
    int limit,
  ) {
    final likeQuery = '%$query%';
    final sql = '''
      SELECT DISTINCT f.id, f.path, f.name, f.description, f.file_type
      FROM files f
      LEFT JOIN exports e ON e.file_id = f.id
      LEFT JOIN variables v ON v.file_id = f.id
      WHERE (
        f.name LIKE ? OR f.description LIKE ? OR f.path LIKE ?
        OR e.name LIKE ? OR v.name LIKE ?
      )
      ORDER BY f.path
      LIMIT ?
    ''';
    final result = database.select(
      sql,
      [likeQuery, likeQuery, likeQuery, likeQuery, likeQuery, limit],
    );
    return _buildRichResults(result, filters);
  }

  /// Build rich results with exports summary from a result set.
  CallToolResult _buildRichResults(
    ResultSet result,
    Map<String, dynamic> filters,
  ) {
    final files = <Map<String, dynamic>>[];
    for (final row in result) {
      final fileId = row['id'] as String;
      final fileEntry = <String, dynamic>{
        'path': row['path'] as String,
        'name': row['name'] as String,
        'description': row['description'],
        'file_type': row['file_type'],
      };

      // Get exports summary for this file
      final exports = database.select(
        'SELECT name, kind FROM exports WHERE file_id = ?',
        [fileId],
      );
      fileEntry['exports'] = exports
          .map((e) => {
                'name': e['name'] as String,
                'kind': e['kind'] as String,
              })
          .toList();

      files.add(fileEntry);
    }

    return jsonResult({
      'files': files,
      'count': files.length,
      'filters': filters,
    });
  }

  /// Find all files that import a given path.
  ///

  /// Given an import path (or pattern), returns all indexed files whose
  /// imports match. Results include file metadata and exports summary.
  CallToolResult dependents(Map<String, dynamic>? args) {
    final importPath = args?['path'] as String?;

    if (requireString(importPath, 'path') case final error?) {
      return error;
    }

    // Search for files that have a matching import
    final result = database.select('''
      SELECT DISTINCT f.id, f.path, f.name, f.description, f.file_type
      FROM files f
      JOIN imports i ON i.file_id = f.id
      WHERE i.import_path LIKE ?
      ORDER BY f.path
    ''', ['%$importPath%']);

    final files = <Map<String, dynamic>>[];
    for (final row in result) {
      final fileId = row['id'] as String;
      final fileEntry = <String, dynamic>{
        'path': row['path'] as String,
        'name': row['name'] as String,
        'description': row['description'],
        'file_type': row['file_type'],
      };

      // Get the specific matching imports
      final matchingImports = database.select(
        'SELECT import_path FROM imports WHERE file_id = ? AND import_path LIKE ?',
        [fileId, '%$importPath%'],
      );
      fileEntry['matching_imports'] =
          matchingImports.map((i) => i['import_path'] as String).toList();

      // Get exports summary
      final exports = database.select(
        'SELECT name, kind FROM exports WHERE file_id = ?',
        [fileId],
      );
      fileEntry['exports'] = exports
          .map((e) => {
                'name': e['name'] as String,
                'kind': e['kind'] as String,
              })
          .toList();

      files.add(fileEntry);
    }

    return jsonResult({
      'dependents': files,
      'count': files.length,
      'import_path_query': importPath,
    });
  }

  /// Get all dependencies (imports) for a specific file.
  ///
  /// Returns the file's imports with an indication of whether each
  /// import is indexed (internal) or external.
  CallToolResult dependencies(Map<String, dynamic>? args) {
    final path = args?['path'] as String?;

    if (requireString(path, 'path') case final error?) {
      return error;
    }

    // Look up the file
    final fileResult = database.select(
      'SELECT id, path, name, description, file_type FROM files WHERE path = ?',
      [path],
    );

    if (fileResult.isEmpty) {
      return notFoundError('File', path!);
    }

    final file = fileResult.first;
    final fileId = file['id'] as String;

    // Get all imports for this file
    final imports = database.select(
      'SELECT import_path FROM imports WHERE file_id = ? ORDER BY import_path',
      [fileId],
    );

    final deps = <Map<String, dynamic>>[];
    for (final imp in imports) {
      final importPath = imp['import_path'] as String;

      // Check if the imported file is indexed (try exact match and common variations)
      final indexed = database.select(
        'SELECT path, name, description, file_type FROM files WHERE path = ? OR path LIKE ?',
        [importPath, '%$importPath'],
      );

      if (indexed.isNotEmpty) {
        final indexedFile = indexed.first;
        deps.add({
          'import_path': importPath,
          'is_indexed': true,
          'resolved_path': indexedFile['path'] as String,
          'name': indexedFile['name'],
          'description': indexedFile['description'],
          'file_type': indexedFile['file_type'],
        });
      } else {
        deps.add({
          'import_path': importPath,
          'is_indexed': false,
        });
      }
    }

    final internal = deps.where((d) => d['is_indexed'] == true).length;
    final external = deps.where((d) => d['is_indexed'] == false).length;

    return jsonResult({
      'file': {
        'path': file['path'],
        'name': file['name'],
        'description': file['description'],
        'file_type': file['file_type'],
      },
      'dependencies': deps,
      'count': deps.length,
      'internal_count': internal,
      'external_count': external,
    });
  }

  /// Search annotations (TODO, FIXME, HACK, etc.) across the codebase.
  ///
  /// Supports filtering by kind, message pattern, file path pattern, and file type.
  CallToolResult searchAnnotations(Map<String, dynamic>? args) {
    final kind = args?['kind'] as String?;
    final messagePattern = args?['message_pattern'] as String?;
    final pathPattern = args?['path_pattern'] as String?;
    final fileType = args?['file_type'] as String?;
    final limit = args?['limit'] as int? ?? 100;

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

    final sql = '''
      SELECT a.kind, a.message, a.line, f.path, f.name, f.file_type
      FROM annotations a
      JOIN files f ON a.file_id = f.id
      $whereClause
      ORDER BY f.path, a.line
      LIMIT ?
    ''';
    values.add(limit);

    final result = database.select(sql, values);

    final annotations = result
        .map((row) => {
              'kind': row['kind'] as String,
              'message': row['message'],
              'line': row['line'],
              'file_path': row['path'] as String,
              'file_name': row['name'] as String,
              'file_type': row['file_type'],
            })
        .toList();

    // Summary by kind
    final kindCounts = <String, int>{};
    for (final a in annotations) {
      final k = a['kind'] as String;
      kindCounts[k] = (kindCounts[k] ?? 0) + 1;
    }

    return jsonResult({
      'annotations': annotations,
      'count': annotations.length,
      'by_kind': kindCounts,
      'filters': filters,
    });
  }
  /// Get aggregate statistics about the code index.
  ///
  /// Returns counts for files (by type), exports (by kind), variables,
  /// imports (with top-imported paths), and annotations (by kind).
  CallToolResult stats(Map<String, dynamic>? args) {
    final topN = args?['limit'] as int? ?? 10;

    // Files
    final totalFiles =
        database.select('SELECT COUNT(*) as cnt FROM files').first['cnt'] as int;
    final filesByType = database.select(
      'SELECT file_type, COUNT(*) as cnt FROM files GROUP BY file_type ORDER BY cnt DESC',
    );

    // Exports
    final totalExports =
        database.select('SELECT COUNT(*) as cnt FROM exports').first['cnt'] as int;
    final exportsByKind = database.select(
      'SELECT kind, COUNT(*) as cnt FROM exports GROUP BY kind ORDER BY cnt DESC',
    );

    // Variables
    final totalVars =
        database.select('SELECT COUNT(*) as cnt FROM variables').first['cnt'] as int;

    // Imports
    final totalImports =
        database.select('SELECT COUNT(*) as cnt FROM imports').first['cnt'] as int;
    final topImported = database.select('''
      SELECT import_path, COUNT(*) as cnt FROM imports
      GROUP BY import_path ORDER BY cnt DESC LIMIT ?
    ''', [topN]);

    // Annotations
    final totalAnnotations =
        database.select('SELECT COUNT(*) as cnt FROM annotations').first['cnt'] as int;
    final annotationsByKind = database.select(
      'SELECT kind, COUNT(*) as cnt FROM annotations GROUP BY kind ORDER BY cnt DESC',
    );

    return jsonResult({
      'files': {
        'total': totalFiles,
        'by_type': Map.fromEntries(
          filesByType.map((r) => MapEntry(
            r['file_type'] as String? ?? 'unknown',
            r['cnt'] as int,
          )),
        ),
      },
      'exports': {
        'total': totalExports,
        'by_kind': Map.fromEntries(
          exportsByKind.map((r) => MapEntry(
            r['kind'] as String,
            r['cnt'] as int,
          )),
        ),
      },
      'variables': {
        'total': totalVars,
      },
      'imports': {
        'total': totalImports,
        'top_imported': topImported
            .map((r) => {
                  'path': r['import_path'] as String,
                  'count': r['cnt'] as int,
                })
            .toList(),
      },
      'annotations': {
        'total': totalAnnotations,
        'by_kind': Map.fromEntries(
          annotationsByKind.map((r) => MapEntry(
            r['kind'] as String,
            r['cnt'] as int,
          )),
        ),
      },
    });
  }
}
