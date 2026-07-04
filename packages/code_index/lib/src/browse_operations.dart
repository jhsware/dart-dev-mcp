/// Layered read operations for the code-index MCP server (design §7.3–§7.4,
/// §7.11): `get-file`, `get-files`, `overview`, and `project-info`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'stale_detection.dart';

/// Browse/read operations handler.
///
/// Serves the cheapest layered reads (`get-file`/`get-files`), the compact
/// `overview` orientation listing, and `project-info` diagnostics. Every
/// file-scoped read surfaces a `needs_reindex` array via [StaleDetector].
class BrowseOperations {
  final Database database;
  final Directory workingDir;
  final List<String> allowedPaths;

  /// Absolute path to the SQLite database file — used by `project-info` to
  /// derive the data directory, registry entry, and schema version. Optional
  /// so unit tests can construct the handler without wiring storage paths.
  final String? dbPath;

  late final StaleDetector _staleDetector;

  BrowseOperations({
    required this.database,
    required this.workingDir,
    this.allowedPaths = const [],
    this.dbPath,
  }) {
    _staleDetector = StaleDetector(database: database, workingDir: workingDir);
  }

  static const _validLayers = {0, 1, 2, 3, 4};

  CallToolResult? _checkAllowed(String relativePath) {
    if (allowedPaths.isEmpty) return null;
    final absolutePath = p.normalize(p.join(workingDir.path, relativePath));
    if (isAllowedPath(allowedPaths, absolutePath)) return null;
    return outOfScopeResponse(
      path: relativePath,
      allowedPaths: getAllowedRelativePaths(workingDir, allowedPaths),
    );
  }

  static const _fileColumns =
      'id, path, name, file_type, language, file_hash, size_bytes, '
      'line_count, word_count, mtime, summary, tags, layers_present, '
      'indexed_at, analysis_status';

  /// `get-file`: one file, selected `layers` (default `[0, 1, 4]`).
  CallToolResult getFile(Map<String, dynamic>? args) {
    final path = args?['path'] as String?;
    final layers = _parseLayers(args?['layers']);

    if (requireString(path, 'path') case final error?) return error;
    if (_checkAllowed(path!) case final error?) return error;
    if (_validateLayers(layers) case final error?) return error;

    final fileResult = database.select(
      'SELECT $_fileColumns FROM files WHERE path = ?',
      [path],
    );

    if (fileResult.isEmpty) {
      return jsonResult({
        'error': 'File not found: $path',
        'needs_reindex': [
          {'path': path, 'reason': 'changed'},
        ],
      });
    }

    final file = fileResult.first;
    final data = _buildLayeredResponse(file, file['id'] as String, layers);
    final needsReindex = _staleDetector.needsReindex([path], layers);

    return jsonResult({...data, 'needs_reindex': needsReindex});
  }

  /// `get-files`: batched [getFile] with an aggregated `needs_reindex`.
  CallToolResult getFiles(Map<String, dynamic>? args) {
    final pathsDynamic = args?['paths'] as List<dynamic>?;
    final layers = _parseLayers(args?['layers']);

    if (pathsDynamic == null || pathsDynamic.isEmpty) {
      return validationError('paths', 'paths is required and must not be empty');
    }
    if (_validateLayers(layers) case final error?) return error;

    final paths = pathsDynamic.map((e) => e.toString()).toList();
    final files = <Map<String, dynamic>>[];

    for (final path in paths) {
      if (_checkAllowed(path) case final error?) return error;

      final fileResult = database.select(
        'SELECT $_fileColumns FROM files WHERE path = ?',
        [path],
      );

      if (fileResult.isEmpty) {
        files.add({'path': path, 'error': 'File not found: $path'});
      } else {
        final file = fileResult.first;
        files.add(_buildLayeredResponse(file, file['id'] as String, layers));
      }
    }

    final needsReindex = _staleDetector.needsReindex(paths, layers);

    return jsonResult({
      'files': files,
      'count': files.length,
      'needs_reindex': needsReindex,
    });
  }

  /// `overview`: compact orientation listing — per file `path`, `summary`,
  /// `tags`, `line_count`, and public symbol names (design §7.4).
  CallToolResult overview(Map<String, dynamic>? args) {
    final pathPattern = args?['path_pattern'] as String?;
    final fileType = args?['file_type'] as String?;
    final language = args?['language'] as String?;
    final limit = args?['limit'] as int? ?? 100;

    if (pathPattern != null && pathPattern.isNotEmpty) {
      if (_checkAllowed(pathPattern) case final error?) return error;
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
    if (language != null && language.isNotEmpty) {
      conditions.add('f.language = ?');
      values.add(language);
      filters['language'] = language;
    }

    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final result = database.select(
      'SELECT f.id, f.path, f.summary, f.tags, f.line_count '
      'FROM files f $whereClause ORDER BY f.path LIMIT ?',
      [...values, limit],
    );

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
        'line_count': row['line_count'],
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

  /// `project-info`: data dir, db path, registry entry, schema version, row
  /// counts, and `last_scan_at` (design §7.11).
  CallToolResult projectInfo(Map<String, dynamic>? args) {
    final schemaVer =
        database.select('PRAGMA user_version').first.values.first as int;

    final rowCounts = <String, int>{};
    for (final table in const [
      'files',
      'symbols',
      'imports',
      'symbol_references',
      'annotations',
    ]) {
      rowCounts[table] =
          database.select('SELECT COUNT(*) AS c FROM $table').first['c'] as int;
    }

    final lastScan = database
        .select('SELECT MAX(indexed_at) AS m FROM files')
        .first['m'] as String?;

    final info = <String, dynamic>{
      'project_path': workingDir.path,
      'schema_version': schemaVer,
      'row_counts': rowCounts,
      'last_scan_at': lastScan,
    };

    if (dbPath != null) {
      final dataDir = p.dirname(dbPath!);
      final dataRoot = p.dirname(dataDir);
      info['db_path'] = dbPath;
      info['data_dir'] = dataDir;
      info['meta'] = _readMeta(dataDir);
      info['registry_entry'] = _readRegistryEntry(dataRoot);
    }

    return jsonResult(info);
  }

  // ── Private helpers ──────────────────────────────────────────────────

  List<int> _parseLayers(dynamic raw) {
    if (raw is List) return raw.map((e) => (e as num).toInt()).toList();
    return [0, 1, 4];
  }

  CallToolResult? _validateLayers(List<int> layers) {
    for (final l in layers) {
      if (!_validLayers.contains(l)) {
        return validationError('layers', 'Invalid layer: $l. Valid: 0,1,2,3,4');
      }
    }
    return null;
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

  Map<String, dynamic>? _readMeta(String dataDir) {
    final file = File(p.join(dataDir, 'meta.json'));
    if (!file.existsSync()) return null;
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _readRegistryEntry(String dataRoot) {
    final file = File(p.join(dataRoot, 'registry.json'));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      final projects = (decoded as Map)['projects'];
      if (projects is Map) {
        final entry = projects[workingDir.path] ??
            projects[p.normalize(p.absolute(workingDir.path))];
        if (entry is Map) return entry.cast<String, dynamic>();
      }
    } catch (_) {
      // Corrupt/absent registry — advisory only.
    }
    return null;
  }

  Map<String, dynamic> _buildLayeredResponse(
    Row file,
    String fileId,
    List<int> layers,
  ) {
    final data = <String, dynamic>{'path': file['path']};

    if (layers.contains(0)) {
      final layersJson = file['layers_present'] as String?;
      data['name'] = file['name'];
      data['file_type'] = file['file_type'];
      data['language'] = file['language'];
      data['file_hash'] = file['file_hash'];
      data['size_bytes'] = file['size_bytes'];
      data['line_count'] = file['line_count'];
      data['word_count'] = file['word_count'];
      data['mtime'] = file['mtime'];
      data['indexed_at'] = file['indexed_at'];
      data['analysis_status'] = file['analysis_status'];
      data['layers_present'] = layersJson != null
          ? (jsonDecode(layersJson) as List<dynamic>).cast<int>()
          : <int>[];
    }

    if (layers.contains(1)) {
      data['summary'] = file['summary'];
      data['tags'] = _decodeTags(file['tags'] as String?);
    }

    final wantStructure =
        layers.contains(2) || layers.contains(3) || layers.contains(4);
    if (wantStructure) {
      final withDetail = layers.contains(2) || layers.contains(3);
      final includeSummaries = layers.contains(3);
      // Layer 4 alone (no 2/3) restricts symbols to the public API.
      final publicOnly = !withDetail;

      data['symbols'] = _symbols(
        fileId,
        publicOnly: publicOnly,
        includeSummaries: includeSummaries,
      );
      data['imports'] = database
          .select(
            'SELECT import_path FROM imports WHERE file_id = ? '
            'ORDER BY import_path',
            [fileId],
          )
          .map((i) => i['import_path'] as String)
          .toList();

      if (withDetail) {
        data['references'] = _references(fileId);
        data['annotations'] = _annotations(fileId);
      }
    }

    return data;
  }

  List<Map<String, dynamic>> _symbols(
    String fileId, {
    required bool publicOnly,
    required bool includeSummaries,
  }) {
    final visFilter = publicOnly ? "AND visibility = 'public'" : '';
    final rows = database.select(
      'SELECT name, kind, visibility, parent, signature, line, end_line, '
      'summary FROM symbols WHERE file_id = ? $visFilter '
      'ORDER BY parent, name',
      [fileId],
    );
    return rows.map((s) {
      final entry = <String, dynamic>{
        'name': s['name'],
        'kind': s['kind'],
        'visibility': s['visibility'],
      };
      if (s['parent'] != null) entry['parent'] = s['parent'];
      if (s['signature'] != null) entry['signature'] = s['signature'];
      if (s['line'] != null) entry['line'] = s['line'];
      if (s['end_line'] != null) entry['end_line'] = s['end_line'];
      if (includeSummaries && s['summary'] != null) {
        entry['summary'] = s['summary'];
      }
      return entry;
    }).toList();
  }

  List<Map<String, dynamic>> _references(String fileId) {
    return database
        .select(
          'SELECT dot_path, symbol, module, source_path, symbol_kind, '
          'resolution, count FROM symbol_references WHERE file_id = ? '
          'ORDER BY count DESC, dot_path',
          [fileId],
        )
        .map((u) => {
              'dot_path': u['dot_path'],
              'symbol': u['symbol'],
              'module': u['module'],
              'source_path': u['source_path'],
              'kind': u['symbol_kind'],
              'resolution': u['resolution'],
              'count': u['count'],
            })
        .toList();
  }

  List<Map<String, dynamic>> _annotations(String fileId) {
    return database
        .select(
          'SELECT kind, message, line FROM annotations WHERE file_id = ? '
          'ORDER BY line',
          [fileId],
        )
        .map((a) => {
              'kind': a['kind'],
              'message': a['message'],
              'line': a['line'],
            })
        .toList();
  }
}
