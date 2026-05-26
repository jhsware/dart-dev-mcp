import 'dart:io';

import 'package:code_index_mcp/code_index_mcp.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

final _uuid = Uuid();

/// Test-only helpers for the code-index package.
///
/// The `indexFile` method used to live on [IndexOperations] as a legacy
/// MCP operation. It was retired from the public surface during the
/// layered-storage rewrite, but the test suite still benefits from a
/// compact "write a synthetic row without touching the filesystem" path
/// for setting up search / browse / diff scenarios. This extension keeps
/// that ergonomic available exclusively inside the test directory.
extension IndexOperationsTestHelpers on IndexOperations {
  /// Insert or update a `files` row plus its `exports`, `variables`,
  /// `imports`, `annotations`, and `code_search_fts` companions from the
  /// supplied structural fields. Bypasses analyzer parsing and disk reads,
  /// which makes it suitable for synthetic test data.
  ///
  /// Mirrors the original `IndexOperations.indexFile` MCP handler signature
  /// so existing tests can keep calling `indexOps.indexFile({...})`.
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

    final absolutePath = p.normalize(p.join(workingDir.path, path!));
    final file = File(absolutePath);
    if (!file.existsSync()) {
      return validationError('path', 'File not found: $path');
    }

    if (allowedPaths.isNotEmpty && !isAllowedPath(allowedPaths, absolutePath)) {
      return outOfScopeResponse(
        path: path,
        allowedPaths: getAllowedRelativePaths(workingDir, allowedPaths),
      );
    }

    final fileHash = computeFileHash(file);
    final now = DateTime.now().toUtc().toIso8601String();

    final existing =
        database.select('SELECT id FROM files WHERE path = ?', [path]);
    final isUpdate = existing.isNotEmpty;
    final fileId = isUpdate ? existing.first['id'] as String : _uuid.v4();
    final message = isUpdate ? 'File index updated' : 'File indexed';

    withRetryTransactionSync(database, () {
      if (isUpdate) {
        database.execute('DELETE FROM exports WHERE file_id = ?', [fileId]);
        database.execute('DELETE FROM variables WHERE file_id = ?', [fileId]);
        database.execute('DELETE FROM imports WHERE file_id = ?', [fileId]);
        database
            .execute('DELETE FROM code_search_fts WHERE file_id = ?', [fileId]);
        database
            .execute('DELETE FROM annotations WHERE file_id = ?', [fileId]);
        database.execute(
            'DELETE FROM external_symbol_usages WHERE file_id = ?', [fileId]);

        database.execute('''
          UPDATE files SET name = ?, description = ?, file_type = ?,
            file_hash = ?, updated_at = ?
          WHERE id = ?
        ''', [name, description, fileType, fileHash, now, fileId]);
      } else {
        database.execute('''
          INSERT INTO files (id, path, name, description, file_type, file_hash,
            created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', [fileId, path, name, description, fileType, fileHash, now, now]);
      }

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
        INSERT INTO code_search_fts (file_id, name, description, export_names,
          export_descriptions, variable_names, file_path, external_symbols)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''', [
        fileId,
        name,
        description ?? '',
        exportNames,
        exportDescriptions,
        variableNames,
        path,
        '',
      ]);
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
}
