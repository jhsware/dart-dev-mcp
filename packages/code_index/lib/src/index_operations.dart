import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'dart_parser.dart';
import 'hash_utils.dart';

final _uuid = Uuid();

/// Index operations handler for the code-index MCP server.
class IndexOperations {
  final Database database;
  final Directory workingDir;
  final List<String> allowedPaths;

  IndexOperations({required this.database, required this.workingDir, this.allowedPaths = const []});

  /// Add or update a file entry in the code index.
  CallToolResult indexFile(Map<String, dynamic>? args) {
    final path = args?['path'] as String?;
    final name = args?['name'] as String?;
    final description = args?['description'] as String?;
    final fileType = args?['file_type'] as String?;
    final exports = args?['exports'] as List<dynamic>?;
    final variables = args?['variables'] as List<dynamic>?;
    final imports = args?['imports'] as List<dynamic>?;
    final annotations = args?['annotations'] as List<dynamic>?;

    if (requireString(path, 'path') case final error?) {
      return error;
    }

    if (requireString(name, 'name') case final error?) {
      return error;
    }

    // Resolve absolute path and read file content for hashing
    final absolutePath = p.normalize(p.join(workingDir.path, path!));
    final file = File(absolutePath);
    if (!file.existsSync()) {
      return validationError('path', 'File not found: $path');
    }

    // Check allowed paths restriction
    if (allowedPaths.isNotEmpty && !isAllowedPath(allowedPaths, absolutePath)) {
      return validationError('path', 'Path not allowed: $path. ${formatAllowedPathsHint(workingDir, allowedPaths)}');
    }

    final fileHash = computeFileHash(file);

    final now = DateTime.now().toUtc().toIso8601String();

    // Check if file with same path already exists
    final existing =
        database.select('SELECT id FROM files WHERE path = ?', [path]);
    final isUpdate = existing.isNotEmpty;
    final fileId = isUpdate ? existing.first['id'] as String : _uuid.v4();
    final message = isUpdate ? 'File index updated' : 'File indexed';

    withRetryTransactionSync(database, () {
      if (isUpdate) {
        // Delete child records (CASCADE would handle this on file delete,
        // but we're updating, so delete children explicitly)
        database.execute('DELETE FROM exports WHERE file_id = ?', [fileId]);
        database.execute('DELETE FROM variables WHERE file_id = ?', [fileId]);
        database.execute('DELETE FROM imports WHERE file_id = ?', [fileId]);
        database
            .execute('DELETE FROM code_search_fts WHERE file_id = ?', [fileId]);
        database
            .execute('DELETE FROM annotations WHERE file_id = ?', [fileId]);

        // Update file record
        database.execute('''
          UPDATE files SET name = ?, description = ?, file_type = ?,
            file_hash = ?, updated_at = ?
          WHERE id = ?
        ''', [name, description, fileType, fileHash, now, fileId]);
      } else {
        // Insert new file record
        database.execute('''
          INSERT INTO files (id, path, name, description, file_type, file_hash,
            created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', [fileId, path, name, description, fileType, fileHash, now, now]);
      }

      // Insert exports
      if (exports != null) {
        for (final export in exports) {
          final e = export as Map<String, dynamic>;
          database.execute('''
            INSERT INTO exports (id, file_id, name, kind, parameters,
              description, parent_name, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''', [
            _uuid.v4(),
            fileId,
            e['name'],
            e['kind'],
            e['parameters'],
            e['description'],
            e['parent_name'],
            now,
            now,
          ]);
        }
      }

      // Insert variables
      if (variables != null) {
        for (final variable in variables) {
          final v = variable as Map<String, dynamic>;
          database.execute('''
            INSERT INTO variables (id, file_id, name, description,
              created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
          ''', [
            _uuid.v4(),
            fileId,
            v['name'],
            v['description'],
            now,
            now,
          ]);
        }
      }

      // Insert imports
      if (imports != null) {
        for (final importPath in imports) {
          database.execute('''
            INSERT INTO imports (id, file_id, import_path, created_at)
            VALUES (?, ?, ?, ?)
          ''', [
            _uuid.v4(),
            fileId,
            importPath as String,
            now,
          ]);
        }
      }

      // Insert annotations (TODO, FIXME, HACK, etc.)
      if (annotations != null) {
        for (final annotation in annotations) {
          final a = annotation as Map<String, dynamic>;
          database.execute('''
            INSERT INTO annotations (id, file_id, kind, message, line, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
          ''', [
            _uuid.v4(),
            fileId,
            a['kind'] as String,
            a['message'],
            a['line'],
            now,
          ]);
        }
      }

      // Sync FTS table
      final exportNames = exports
              ?.map((e) => (e as Map<String, dynamic>)['name'] as String?)
              .where((n) => n != null)
              .join(' ') ??
          '';
      final exportDescriptions = exports
              ?.map((e) =>
                  (e as Map<String, dynamic>)['description'] as String?)
              .where((d) => d != null)
              .join(' ') ??
          '';
      final variableNames = variables
              ?.map((v) => (v as Map<String, dynamic>)['name'] as String?)
              .where((n) => n != null)
              .join(' ') ??
          '';
      database.execute('''
        INSERT INTO code_search_fts (file_id, name, description, export_names, export_descriptions, variable_names, file_path)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      ''', [fileId, name, description ?? '', exportNames, exportDescriptions, variableNames, path]);
    });

    return jsonResult({
      'success': true,
      'message': message,
      'file': {
        'id': fileId,
        'path': path,
        'name': name,
        'file_hash': fileHash,
        'export_count': exports?.length ?? 0,
        'variable_count': variables?.length ?? 0,
        'import_count': imports?.length ?? 0,
        'annotation_count': annotations?.length ?? 0,
      },
    });
  }

  /// Automatically index a file by reading it and extracting metadata.
  ///
  /// For Dart files, uses [DartParser] to programmatically extract all
  /// structural metadata (imports, exports, variables, annotations).
  /// For non-Dart files, stores path, name, file_type, and the optional
  /// LLM-provided description.
  CallToolResult autoIndex(Map<String, dynamic>? args) {
    final path = args?['path'] as String?;
    final description = args?['description'] as String?;

    if (requireString(path, 'path') case final error?) {
      return error;
    }

    // Resolve and validate file
    final absolutePath = p.normalize(p.join(workingDir.path, path!));
    final file = File(absolutePath);
    if (!file.existsSync()) {
      return validationError('path', 'File not found: $path');
    }

    // Check allowed paths restriction
    if (allowedPaths.isNotEmpty && !isAllowedPath(allowedPaths, absolutePath)) {
      return validationError('path', 'Path not allowed: $path. ${formatAllowedPathsHint(workingDir, allowedPaths)}');
    }

    final name = p.basename(path);
    final ext = p.extension(path).toLowerCase();
    final fileType = ext.isNotEmpty ? ext.substring(1) : null;

    List<Map<String, String?>> exports = [];
    List<Map<String, String?>> variables = [];
    List<String> imports = [];
    List<Map<String, dynamic>> annotations = [];

    if (fileType == 'dart') {
      final source = file.readAsStringSync();
      final result = DartParser.parse(source);
      exports = result.exports;
      variables = result.variables;
      imports = result.imports;
      annotations = result.annotations;
    }

    // Delegate to indexFile with the extracted data
    return indexFile({
      'path': path,
      'name': name,
      'description': description,
      'file_type': fileType,
      'exports': exports,
      'variables': variables,
      'imports': imports,
      'annotations': annotations,
    });
  }
}
