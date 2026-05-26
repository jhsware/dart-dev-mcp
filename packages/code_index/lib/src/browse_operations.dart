import 'dart:convert';
import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'stale_detection.dart';

/// Browse operations handler for the code-index MCP server.
///
/// Provides layered reads (`get-file`, `get-files`) and a compact overview.
class BrowseOperations {
  final Database database;
  final Directory workingDir;
  final List<String> allowedPaths;
  late final StaleDetector _staleDetector;

  BrowseOperations({
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

  static const _validLayers = {0, 1, 2, 3, 4};

  /// Get a single file with layered data.
  ///
  /// Parameters:
  /// - `path` (required): relative path from project root
  /// - `layers` (optional, default `[0, 1, 4]`): which layers to return
  ///
  /// Returns the requested layers populated from the DB, plus a
  /// `needs_reindex` array for stale detection.
  CallToolResult getFile(Map<String, dynamic>? args) {
    final path = args?['path'] as String?;
    final layers = _parseLayers(args?['layers']);

    if (requireString(path, 'path') case final error?) {
      return error;
    }

    if (_checkAllowed(path!) case final error?) {
      return error;
    }

    // Validate layers
    for (final l in layers) {
      if (!_validLayers.contains(l)) {
        return validationError('layers', 'Invalid layer: $l. Valid: 0,1,2,3,4');
      }
    }

    final fileResult = database.select(
      'SELECT id, path, name, description, file_type, file_hash, '
      'size_bytes, line_count, word_count, mtime, short_summary, '
      'layers_present, last_analyzed_at, analysis_status, '
      'created_at, updated_at '
      'FROM files WHERE path = ?',
      [path],
    );

    if (fileResult.isEmpty) {
      return jsonResult({
        'error': 'File not found: $path',
        'needs_reindex': [
          {'path': path, 'reason': 'changed'}
        ],
      });
    }

    final file = fileResult.first;
    final fileId = file['id'] as String;

    final data = _buildLayeredResponse(file, fileId, layers);
    final needsReindex = _staleDetector.needsReindex([path], layers);

    return jsonResult({
      ...data,
      'needs_reindex': needsReindex,
    });
  }

  /// Get multiple files with layered data.
  ///
  /// Parameters:
  /// - `paths` (required): list of relative paths
  /// - `layers` (optional, default `[0, 1, 4]`): which layers to return
  ///
  /// Returns parallel file responses plus an aggregated `needs_reindex` array.
  CallToolResult getFiles(Map<String, dynamic>? args) {
    final pathsDynamic = args?['paths'] as List<dynamic>?;
    final layers = _parseLayers(args?['layers']);

    if (pathsDynamic == null || pathsDynamic.isEmpty) {
      return validationError('paths', 'paths is required and must not be empty');
    }

    final paths = pathsDynamic.cast<String>();

    // Validate layers
    for (final l in layers) {
      if (!_validLayers.contains(l)) {
        return validationError('layers', 'Invalid layer: $l. Valid: 0,1,2,3,4');
      }
    }

    final files = <Map<String, dynamic>>[];
    final allPaths = <String>[];

    for (final path in paths) {
      if (_checkAllowed(path) case final error?) {
        return error;
      }

      final fileResult = database.select(
        'SELECT id, path, name, description, file_type, file_hash, '
        'size_bytes, line_count, word_count, mtime, short_summary, '
        'layers_present, last_analyzed_at, analysis_status, '
        'created_at, updated_at '
        'FROM files WHERE path = ?',
        [path],
      );

      if (fileResult.isEmpty) {
        files.add({
          'path': path,
          'error': 'File not found: $path',
        });
      } else {
        final file = fileResult.first;
        final fileId = file['id'] as String;
        files.add(_buildLayeredResponse(file, fileId, layers));
      }
      allPaths.add(path);
    }

    final needsReindex = _staleDetector.needsReindex(allPaths, layers);

    return jsonResult({
      'files': files,
      'count': files.length,
      'needs_reindex': needsReindex,
    });
  }

  /// Get a compact overview of all indexed files.
  ///
  /// Returns all files sorted by path with: path, description, file_type,
  /// and compact exports list. Includes `needs_reindex` for returned files.
  CallToolResult overview(Map<String, dynamic>? args) {
    final pathPattern = args?['path_pattern'] as String?;
    final fileType = args?['file_type'] as String?;

    if (pathPattern != null && pathPattern.isNotEmpty) {
      if (_checkAllowed(pathPattern) case final error?) {
        return error;
      }
    }

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
    final filePaths = <String>[];
    for (final row in result) {
      final fileId = row['id'] as String;
      final filePath = row['path'] as String;
      filePaths.add(filePath);

      final exports = database.select(
        'SELECT name, kind FROM exports WHERE file_id = ? ORDER BY name',
        [fileId],
      );
      final compactExports =
          exports.map((e) => '${e['name']} (${e['kind']})').toList();

      files.add({
        'path': filePath,
        'description': row['description'],
        'file_type': row['file_type'],
        'exports': compactExports,
      });
    }

    // Hash-check only returned files; use layers [0] since overview is metadata-only
    final needsReindex = _staleDetector.checkPaths(filePaths);

    return jsonResult({
      'files': files,
      'count': files.length,
      'filters': filters,
      'needs_reindex': needsReindex,
    });
  }

  // ── Private helpers ──────────────────────────────────────────────────

  List<int> _parseLayers(dynamic raw) {
    if (raw == null) return [0, 1, 4];
    if (raw is List) return raw.map((e) => e as int).toList();
    return [0, 1, 4];
  }

  Map<String, dynamic> _buildLayeredResponse(
    Row file,
    String fileId,
    List<int> layers,
  ) {
    final data = <String, dynamic>{};

    // Layer 0: filesystem metadata
    if (layers.contains(0)) {
      final layersJson = file['layers_present'] as String?;
      final layersPresent = layersJson != null
          ? (jsonDecode(layersJson) as List<dynamic>).cast<int>()
          : <int>[];

      data['path'] = file['path'];
      data['name'] = file['name'];
      data['file_type'] = file['file_type'];
      data['file_hash'] = file['file_hash'];
      data['size_bytes'] = file['size_bytes'];
      data['line_count'] = file['line_count'];
      data['word_count'] = file['word_count'];
      data['mtime'] = file['mtime'];
      data['indexed_at'] = file['last_analyzed_at'];
      data['layers_present'] = layersPresent;
      data['analysis_status'] = file['analysis_status'];
    } else {
      // Always include path for identification
      data['path'] = file['path'];
    }

    // Layer 1: short summary
    if (layers.contains(1)) {
      data['short_summary'] = file['short_summary'];
    }

    // Layer 2: declarations (all exports, variables, imports, usages)
    final wantDeclarations = layers.contains(2) || layers.contains(3) || layers.contains(4);
    if (wantDeclarations) {
      final allExports = database.select(
        'SELECT name, kind, parameters, parent_name, description FROM exports WHERE file_id = ? ORDER BY parent_name, name',
        [fileId],
      );

      final includeDescriptions = layers.contains(3);
      final publicOnly = layers.contains(4) && !layers.contains(2);

      final exports = allExports
          .where((e) => !publicOnly || !_isPrivate(e['name'] as String))
          .map((e) {
        final entry = <String, dynamic>{
          'name': e['name'],
          'kind': e['kind'],
        };
        if (e['parameters'] != null) entry['parameters'] = e['parameters'];
        if (e['parent_name'] != null) entry['parent_name'] = e['parent_name'];
        if (includeDescriptions && e['description'] != null) {
          entry['description'] = e['description'];
        }
        return entry;
      }).toList();

      data['exports'] = exports;

      final allVariables = database.select(
        'SELECT name, description FROM variables WHERE file_id = ? ORDER BY name',
        [fileId],
      );

      data['variables'] = allVariables
          .where((v) => !publicOnly || !_isPrivate(v['name'] as String))
          .map((v) {
        final entry = <String, dynamic>{'name': v['name']};
        if (includeDescriptions && v['description'] != null) {
          entry['description'] = v['description'];
        }
        return entry;
      }).toList();

      final imports = database.select(
        'SELECT import_path FROM imports WHERE file_id = ? ORDER BY import_path',
        [fileId],
      );
      data['imports'] = imports.map((i) => i['import_path'] as String).toList();

      if (layers.contains(2) || layers.contains(3)) {
        final usages = database.select(
          'SELECT dot_path, symbol, module, source_path, symbol_kind, reference_count '
          'FROM external_symbol_usages WHERE file_id = ? ORDER BY dot_path',
          [fileId],
        );
        data['external_usages'] = usages
            .map((u) => {
                  'dot_path': u['dot_path'],
                  'symbol': u['symbol'],
                  'module': u['module'],
                  'source_path': u['source_path'],
                  'kind': u['symbol_kind'],
                  'reference_count': u['reference_count'],
                })
            .toList();
      }
    }

    return data;
  }

  bool _isPrivate(String name) => name.startsWith('_');
}
