import 'dart:convert';
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
  ///
  /// Retained as an internal helper for backward-compatible test setup.
  /// Not exposed as an MCP operation.
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
      return outOfScopeResponse(
        path: path,
        allowedPaths: getAllowedRelativePaths(workingDir, allowedPaths),
      );
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
        // Delete child records
        database.execute('DELETE FROM exports WHERE file_id = ?', [fileId]);
        database.execute('DELETE FROM variables WHERE file_id = ?', [fileId]);
        database.execute('DELETE FROM imports WHERE file_id = ?', [fileId]);
        database
            .execute('DELETE FROM code_search_fts WHERE file_id = ?', [fileId]);
        database
            .execute('DELETE FROM annotations WHERE file_id = ?', [fileId]);
        database
            .execute('DELETE FROM external_symbol_usages WHERE file_id = ?', [fileId]);

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
        INSERT INTO code_search_fts (file_id, name, description, export_names,
          export_descriptions, variable_names, file_path, external_symbols)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''', [fileId, name, description ?? '', exportNames, exportDescriptions, variableNames, path, '']);
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

  /// Layer-aware auto-index: the single MCP write entry point.
  ///
  /// Accepts:
  /// - `path` (required): relative path from project root
  /// - `layers` (optional, default `[0, 1, 2, 3]`): which layers to produce
  /// - `short_summary` (layer 1)
  /// - `symbol_summaries` (layer 3, map of symbol_name → description)
  /// - For non-Dart files: `exports`, `variables`, `imports`, `annotations`
  Future<CallToolResult> autoIndex(Map<String, dynamic>? args) async {
    final path = args?['path'] as String?;
    final layers = (args?['layers'] as List<dynamic>?)
            ?.map((e) => e as int)
            .toList() ??
        [0, 1, 2, 3];
    final shortSummary = args?['short_summary'] as String?;
    final symbolSummaries = args?['symbol_summaries'] as Map<String, dynamic>?;

    if (requireString(path, 'path') case final error?) {
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

    final name = p.basename(path);
    final ext = p.extension(path).toLowerCase();
    final fileType = ext.isNotEmpty ? ext.substring(1) : null;
    final isDart = fileType == 'dart';
    final now = DateTime.now().toUtc().toIso8601String();

    // ── Layer 0: filesystem metadata ──────────────────────────────────
    final fileContent = file.readAsStringSync();
    final fileHash = computeFileHash(file);
    final fileStat = file.statSync();
    final sizeBytes = fileStat.size;
    final lineCount = fileContent.split('\n').length;
    final wordCount = fileContent
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;
    final mtime = fileStat.modified.toUtc().toIso8601String();

    // ── Layer 2: declarations + external usages ──────────────────────
    var exports = <Map<String, String?>>[];
    var variables = <Map<String, String?>>[];
    var imports = <String>[];
    var annotations = <Map<String, dynamic>>[];
    var externalUsages = <ExternalSymbolUsage>[];

    if (isDart && layers.contains(2)) {
      // Syntactic parse for declarations
      final parseResult = DartParser.parse(fileContent);
      exports = parseResult.exports;
      variables = parseResult.variables;
      imports = parseResult.imports;
      annotations = parseResult.annotations;

      // Attempt resolved analysis for external usages
      try {
        final results = await DartResolvedParser.resolveExternalUsages(
          projectPath: workingDir.path,
          filePaths: [absolutePath],
        );
        if (results.isNotEmpty) {
          externalUsages = results.first.externalUsages;
        }
      } catch (_) {
        // Resolved analysis unavailable — proceed without usages
      }
    } else if (!isDart && layers.contains(2)) {
      // Non-Dart: accept manual structural fields
      final manualExports = args?['exports'] as List<dynamic>?;
      final manualVariables = args?['variables'] as List<dynamic>?;
      final manualImports = args?['imports'] as List<dynamic>?;
      final manualAnnotations = args?['annotations'] as List<dynamic>?;

      if (manualExports != null) {
        exports = manualExports
            .map((e) => (e as Map<String, dynamic>)
                .map((k, v) => MapEntry(k, v?.toString())))
            .toList();
      }
      if (manualVariables != null) {
        variables = manualVariables
            .map((v) => (v as Map<String, dynamic>)
                .map((k, v) => MapEntry(k, v?.toString())))
            .toList();
      }
      if (manualImports != null) {
        imports = manualImports.cast<String>();
      }
      if (manualAnnotations != null) {
        annotations = manualAnnotations.cast<Map<String, dynamic>>();
      }
    }

    // ── Layer 3: per-symbol descriptions ─────────────────────────────
    if (layers.contains(3) && symbolSummaries != null) {
      for (final export in exports) {
        final n = export['name'];
        if (n != null && symbolSummaries.containsKey(n)) {
          export['description'] = symbolSummaries[n] as String?;
        }
      }
    }

    // ── Compute layers_present ───────────────────────────────────────
    final layersPresent = <int>[];
    if (layers.contains(0)) layersPresent.add(0);
    if (layers.contains(1) && shortSummary != null) layersPresent.add(1);
    if (layers.contains(2)) layersPresent.add(2);
    if (layers.contains(3) && symbolSummaries != null) layersPresent.add(3);

    // ── DB writes ────────────────────────────────────────────────────
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
        database.execute('DELETE FROM code_search_fts WHERE file_id = ?', [fileId]);
        database.execute('DELETE FROM annotations WHERE file_id = ?', [fileId]);
        database.execute('DELETE FROM external_symbol_usages WHERE file_id = ?', [fileId]);

        database.execute('''
          UPDATE files SET name = ?, description = ?, file_type = ?,
            file_hash = ?, size_bytes = ?, line_count = ?, word_count = ?,
            mtime = ?, short_summary = ?, layers_present = ?,
            last_analyzed_at = ?, analysis_status = 'fresh',
            analysis_error = NULL, updated_at = ?
          WHERE id = ?
        ''', [
          name, shortSummary, fileType, fileHash, sizeBytes, lineCount,
          wordCount, mtime, shortSummary, jsonEncode(layersPresent),
          now, now, fileId,
        ]);
      } else {
        database.execute('''
          INSERT INTO files (id, path, name, description, file_type, file_hash,
            size_bytes, line_count, word_count, mtime, short_summary,
            layers_present, last_analyzed_at, analysis_status,
            created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'fresh', ?, ?)
        ''', [
          fileId, path, name, shortSummary, fileType, fileHash,
          sizeBytes, lineCount, wordCount, mtime, shortSummary,
          jsonEncode(layersPresent), now, now, now,
        ]);
      }

      // Insert exports
      for (final export in exports) {
        database.execute('''
          INSERT INTO exports (id, file_id, name, kind, parameters,
            description, parent_name, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', [
          _uuid.v4(), fileId, export['name'], export['kind'],
          export['parameters'], export['description'], export['parent_name'],
          now, now,
        ]);
      }

      // Insert variables
      for (final variable in variables) {
        database.execute('''
          INSERT INTO variables (id, file_id, name, description,
            created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [_uuid.v4(), fileId, variable['name'], variable['description'], now, now]);
      }

      // Insert imports
      for (final importPath in imports) {
        database.execute('''
          INSERT INTO imports (id, file_id, import_path, created_at)
          VALUES (?, ?, ?, ?)
        ''', [_uuid.v4(), fileId, importPath, now]);
      }

      // Insert annotations
      for (final annotation in annotations) {
        database.execute('''
          INSERT INTO annotations (id, file_id, kind, message, line, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
        ''', [
          _uuid.v4(), fileId, annotation['kind'], annotation['message'],
          annotation['line'], now,
        ]);
      }

      // Insert external_symbol_usages
      for (final usage in externalUsages) {
        database.execute('''
          INSERT INTO external_symbol_usages (id, file_id, module, source_path,
            symbol, symbol_kind, dot_path, reference_count, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', [
          _uuid.v4(), fileId, usage.module, usage.sourcePath,
          usage.symbol, usage.symbolKind, usage.dotPath,
          usage.referenceCount, now, now,
        ]);
      }

      // Sync FTS table
      final exportNames = exports
          .map((e) => e['name'])
          .where((n) => n != null)
          .join(' ');
      final exportDescriptions = exports
          .map((e) => e['description'])
          .where((d) => d != null)
          .join(' ');
      final variableNames = variables
          .map((v) => v['name'])
          .where((n) => n != null)
          .join(' ');
      final externalSymbolsText =
          externalUsages.map((u) => u.dotPath).join(' ');

      database.execute('''
        INSERT INTO code_search_fts (file_id, name, description, export_names,
          export_descriptions, variable_names, file_path, external_symbols)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''', [
        fileId, name, shortSummary ?? '', exportNames, exportDescriptions,
        variableNames, path, externalSymbolsText,
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
        'layers_present': layersPresent,
        'export_count': exports.length,
        'variable_count': variables.length,
        'import_count': imports.length,
        'annotation_count': annotations.length,
        'external_usage_count': externalUsages.length,
      },
    });
  }
}
