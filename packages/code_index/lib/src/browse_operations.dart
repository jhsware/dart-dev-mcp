import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart';

/// Browse operations handler for the code-index MCP server.
///
/// Provides operations for browsing the code index: getting an overview
/// of all indexed files and viewing file API summaries.
class BrowseOperations {
  final Database database;

  BrowseOperations({required this.database});

  /// Get a focused summary of a file's API surface.
  ///
  /// Returns file path, description, exports grouped by parent (class),
  /// and variables. Does NOT include file_hash, created_at, updated_at,
  /// imports, or annotations.
  CallToolResult fileSummary(Map<String, dynamic>? args) {
    final path = args?['path'] as String?;

    if (requireString(path, 'path') case final error?) {
      return error;
    }

    // Look up the file
    final fileResult = database.select(
      'SELECT id, path, description FROM files WHERE path = ?',
      [path],
    );

    if (fileResult.isEmpty) {
      return notFoundError('File', path!);
    }

    final file = fileResult.first;
    final fileId = file['id'] as String;

    // Get exports grouped by parent_name
    final exports = database.select(
      'SELECT name, kind, parameters, description, parent_name FROM exports WHERE file_id = ? ORDER BY parent_name, name',
      [fileId],
    );

    // Group exports by parent
    final groupedExports = <String, List<Map<String, dynamic>>>{};
    for (final e in exports) {
      final parentName = (e['parent_name'] as String?) ?? 'top_level';
      groupedExports.putIfAbsent(parentName, () => []);

      final exportEntry = <String, dynamic>{
        'name': e['name'],
        'kind': e['kind'],
      };
      if (e['parameters'] != null) {
        exportEntry['parameters'] = e['parameters'];
      }
      if (e['description'] != null) {
        exportEntry['description'] = e['description'];
      }
      groupedExports[parentName]!.add(exportEntry);
    }

    // Get variables
    final variables = database.select(
      'SELECT name, description FROM variables WHERE file_id = ? ORDER BY name',
      [fileId],
    );

    return jsonResult({
      'path': file['path'],
      'description': file['description'],
      'exports': groupedExports,
      'variables': variables
          .map((v) {
            final entry = <String, dynamic>{'name': v['name']};
            if (v['description'] != null) {
              entry['description'] = v['description'];
            }
            return entry;
          })
          .toList(),
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
      'annotations': database
          .select(
            'SELECT kind, message, line FROM annotations WHERE file_id = ? ORDER BY line',
            [fileId],
          )
          .map((a) => {
                'kind': a['kind'],
                'message': a['message'],
                'line': a['line'],
              })
          .toList(),
    });
  }

  /// Get a compact overview of all indexed files.

  ///
  /// Returns all files sorted by path with: path, description, file_type,
  /// and compact exports list (names and kinds only, as "name (kind)" strings).
  /// Supports optional path_pattern and file_type filters.
  CallToolResult overview(Map<String, dynamic>? args) {
    final pathPattern = args?['path_pattern'] as String?;
    final fileType = args?['file_type'] as String?;

    final conditions = <String>[];
    final values = <Object?>[];
    final filters = <String, dynamic>{};

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
      SELECT f.id, f.path, f.description, f.file_type
      FROM files f
      $whereClause
      ORDER BY f.path
    ''';

    final result = database.select(sql, values);

    final files = <Map<String, dynamic>>[];
    for (final row in result) {
      final fileId = row['id'] as String;

      // Get compact exports: just name and kind
      final exports = database.select(
        'SELECT name, kind FROM exports WHERE file_id = ? ORDER BY name',
        [fileId],
      );
      final compactExports = exports
          .map((e) => '${e['name']} (${e['kind']})')
          .toList();

      files.add({
        'path': row['path'] as String,
        'description': row['description'],
        'file_type': row['file_type'],
        'exports': compactExports,
      });
    }

    return jsonResult({
      'files': files,
      'count': files.length,
      'filters': filters,
    });
  }
}
