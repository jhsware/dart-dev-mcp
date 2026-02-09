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

    // General text search across multiple fields
    if (query != null && query.isNotEmpty) {
      joins.add('LEFT JOIN exports e ON e.file_id = f.id');
      joins.add('LEFT JOIN variables v ON v.file_id = f.id');
      final likeQuery = '%$query%';
      conditions.add('''(
        f.name LIKE ? OR f.description LIKE ? OR f.path LIKE ?
        OR e.name LIKE ? OR v.name LIKE ?
      )''');
      values.addAll([likeQuery, likeQuery, likeQuery, likeQuery, likeQuery]);
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

    // Build the query - returns rich file metadata
    final joinClause = joins.join('\n');
    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final sql = '''
      SELECT DISTINCT f.id, f.path, f.name, f.description, f.file_type
      FROM files f
      $joinClause
      $whereClause
      ORDER BY f.path
      LIMIT ?
    ''';
    values.add(limit);

    final result = database.select(sql, values);

    // Build rich results with exports summary
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

  /// Show full indexed information for a specific file.
  ///
  /// Returns file metadata, all exports (with full details), all variables,
  /// and all imports for the given file path.
  CallToolResult showFile(Map<String, dynamic>? args) {
    final path = args?['path'] as String?;

    if (requireString(path, 'path') case final error?) {
      return error;
    }

    // Look up the file
    final fileResult = database.select(
      'SELECT id, path, name, description, file_type, file_hash, created_at, updated_at FROM files WHERE path = ?',
      [path],
    );

    if (fileResult.isEmpty) {
      return notFoundError('File', path!);
    }

    final file = fileResult.first;
    final fileId = file['id'] as String;

    // Get all exports with full details
    final exports = database.select(
      'SELECT name, kind, parameters, description, parent_name FROM exports WHERE file_id = ? ORDER BY parent_name, name',
      [fileId],
    );

    // Get all variables
    final variables = database.select(
      'SELECT name, description FROM variables WHERE file_id = ? ORDER BY name',
      [fileId],
    );

    // Get all imports
    final imports = database.select(
      'SELECT import_path FROM imports WHERE file_id = ? ORDER BY import_path',
      [fileId],
    );

    return jsonResult({
      'file': {
        'path': file['path'],
        'name': file['name'],
        'description': file['description'],
        'file_type': file['file_type'],
        'file_hash': file['file_hash'],
        'created_at': file['created_at'],
        'updated_at': file['updated_at'],
      },
      'exports': exports
          .map((e) => {
                'name': e['name'],
                'kind': e['kind'],
                'parameters': e['parameters'],
                'description': e['description'],
                'parent_name': e['parent_name'],
              })
          .toList(),
      'variables': variables
          .map((v) => {
                'name': v['name'],
                'description': v['description'],
              })
          .toList(),
      'imports': imports.map((i) => i['import_path'] as String).toList(),
    });
  }
}
