/// The single MCP write path: `index-files` (design §7.2, §8.5).
///
/// Persists 1..N records in one call. Each file commits in its own
/// transaction (transactional replace-all, §8.5.1) so one bad record cannot
/// poison the batch. Dart structure (layer 2) is computed by the warm
/// analyzer; non-Dart structure comes from the agent record. After the batch,
/// direct Dart dependents are re-resolved unless `refresh_dependents:false`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'dart_extractor.dart';
import 'record_normalize.dart';
import 'reference_refresh.dart';

final _uuid = Uuid();

/// A row destined for the `symbols` table, from either extraction route.
class _WriteSymbol {
  final String name;
  final String kind;
  final String visibility;
  final String? parent;
  final String? signature;
  final int? line;
  final int? endLine;
  String? summary;

  _WriteSymbol({
    required this.name,
    required this.kind,
    required this.visibility,
    this.parent,
    this.signature,
    this.line,
    this.endLine,
    this.summary,
  });
}

/// Outcome of writing one record.
class _FileResult {
  final String path;
  final bool isDart;
  final List<String> warnings;
  _FileResult(this.path, this.isDart, this.warnings);
}

/// Handles the `index-files` operation for the code-index MCP server.
class WriteOperations {
  final Database database;
  final Directory workingDir;
  final List<String> allowedPaths;
  final DartExtractor extractor;

  WriteOperations({
    required this.database,
    required this.workingDir,
    this.allowedPaths = const [],
    DartExtractor? extractor,
  }) : extractor = extractor ?? DartExtractor(projectPath: workingDir.path);

  /// `index-files`: batched write of `files[]` with optional
  /// `refresh_dependents` (default true).
  Future<CallToolResult> indexFiles(Map<String, dynamic>? args) async {
    final files = args?['files'] as List<dynamic>?;
    if (files == null || files.isEmpty) {
      return validationError(
        'files',
        'files[] must contain at least one record',
      );
    }
    final refreshDependents = args?['refresh_dependents'] as bool? ?? true;

    final indexed = <String>[];
    final failed = <Map<String, dynamic>>[];
    final warnings = <Map<String, dynamic>>[];
    final indexedPaths = <String>{};
    final changedDart = <String>[];

    for (final raw in files) {
      final record = (raw as Map).cast<String, dynamic>();
      final path = record['path'] as String?;
      try {
        final result = await _indexOne(record);
        if (result == null) continue; // validation/out-of-scope short-circuit
        indexed.add(result.path);
        indexedPaths.add(result.path);
        if (result.isDart) changedDart.add(result.path);
        for (final w in result.warnings) {
          warnings.add({'path': result.path, 'warning': w});
        }
      } catch (e) {
        failed.add({'path': path ?? '(unknown)', 'error': e.toString()});
        if (path != null) _markFailed(path, e.toString());
      }
    }

    var dependentsRefreshed = <String>[];
    if (refreshDependents && changedDart.isNotEmpty) {
      dependentsRefreshed = await ReferenceRefresh(
        database: database,
        workingDir: workingDir,
        extractor: extractor,
      ).refresh(changedDart, excludePaths: indexedPaths);
    }

    return jsonResult({
      'indexed': indexed,
      'failed': failed,
      'warnings': warnings,
      'dependents_refreshed': dependentsRefreshed,
      'summary': {
        'indexed': indexed.length,
        'failed': failed.length,
        'dependents_refreshed': dependentsRefreshed.length,
      },
    });
  }

  /// Validate + write one record. Returns null when the record is rejected
  /// (missing path / not found / out of scope); throws on write failure so the
  /// caller can record it in `failed[]`.
  Future<_FileResult?> _indexOne(Map<String, dynamic> record) async {
    final path = record['path'] as String?;
    if (requireString(path, 'path') != null) return null;

    final absPath = p.normalize(p.join(workingDir.path, path!));
    final file = File(absPath);
    if (!file.existsSync()) {
      throw StateError('File not found: $path');
    }
    if (allowedPaths.isNotEmpty && !isAllowedPath(allowedPaths, absPath)) {
      throw StateError('Out of scope: $path');
    }

    final name = p.basename(path);
    final ext = p.extension(path).toLowerCase();
    final fileType = ext.isNotEmpty ? ext.substring(1) : null;
    final isDart = fileType == 'dart';

    final normalized = normalizeRecord(
      record: record,
      relPath: path,
      file: file,
      name: name,
      fileType: fileType,
    );

    late final List<_WriteSymbol> symbols;
    late final List<String> imports;
    late final List<SymbolReference> references;
    late final List<Map<String, dynamic>> annotations;
    bool hasStructure;

    if (isDart) {
      final extracted = await _extractDart(absPath, file);
      symbols = _dartSymbols(extracted, normalized.symbolSummaries);
      imports = extracted.imports;
      references = extracted.references;
      annotations = extracted.annotations;
      hasStructure = true;
    } else {
      symbols = normalized.symbols
          .map(
            (s) => _WriteSymbol(
              name: s.name,
              kind: s.kind,
              visibility: s.visibility,
              parent: s.parent,
              signature: s.signature,
              line: s.line,
              endLine: s.endLine,
              summary: s.summary,
            ),
          )
          .toList();
      imports = normalized.imports;
      references = normalized.references;
      annotations = normalized.annotations;
      hasStructure = normalized.hasStructure;
    }

    final layersPresent = deriveLayersPresent(
      hasSummary: normalized.summary != null,
      hasStructure: hasStructure,
      hasSymbolSummaries: normalized.symbolSummaries.isNotEmpty,
    );

    _write(
      normalized,
      symbols,
      imports,
      references,
      annotations,
      layersPresent,
    );
    return _FileResult(path, isDart, normalized.warnings);
  }

  Future<ExtractedFile> _extractDart(String absPath, File file) async {
    try {
      await extractor.notifyChanged(absPath);
      return await extractor.extractFile(absPath);
    } catch (_) {
      return DartExtractor.extractSyntactic(file.readAsStringSync());
    }
  }

  /// Map extracted Dart symbols to write rows, applying layer-3 summaries.
  /// Keys match on `Parent.name` (members) then bare `Name`.
  List<_WriteSymbol> _dartSymbols(
    ExtractedFile extracted,
    Map<String, String> summaries,
  ) {
    return extracted.symbols.map((s) {
      final qualified = s.parent != null ? '${s.parent}.${s.name}' : s.name;
      final summary = summaries[qualified] ?? summaries[s.name];
      return _WriteSymbol(
        name: s.name,
        kind: s.kind,
        visibility: s.visibility,
        parent: s.parent,
        signature: s.signature,
        line: s.line,
        endLine: s.endLine,
        summary: summary,
      );
    }).toList();
  }

  /// Transactional replace-all for one file (§8.5.1).
  void _write(
    NormalizedRecord rec,
    List<_WriteSymbol> symbols,
    List<String> imports,
    List<SymbolReference> references,
    List<Map<String, dynamic>> annotations,
    List<int> layersPresent,
  ) {
    final now = DateTime.now().toUtc().toIso8601String();
    final existing = database.select(
      'SELECT id, created_at FROM files WHERE path = ?',
      [rec.path],
    );
    final isUpdate = existing.isNotEmpty;
    final fileId = isUpdate ? existing.first['id'] as String : _uuid.v4();
    final createdAt = isUpdate ? existing.first['created_at'] as String : now;

    withRetryTransactionSync(database, () {
      if (isUpdate) {
        for (final t in const [
          'symbols',
          'imports',
          'symbol_references',
          'annotations',
        ]) {
          database.execute('DELETE FROM $t WHERE file_id = ?', [fileId]);
        }
        database.execute('DELETE FROM code_index_fts WHERE file_id = ?', [
          fileId,
        ]);
      }

      database.execute(
        '''
        INSERT OR REPLACE INTO files (id, path, name, file_type, language,
          file_hash, size_bytes, line_count, word_count, mtime, summary, tags,
          layers_present, indexed_at, structure_refreshed_at, analysis_status,
          analysis_error, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'fresh', NULL, ?, ?)
        ''',
        [
          fileId,
          rec.path,
          rec.name,
          rec.fileType,
          rec.language,
          rec.fileHash,
          rec.sizeBytes,
          rec.lineCount,
          rec.wordCount,
          rec.mtime,
          rec.summary,
          jsonEncode(rec.tags),
          jsonEncode(layersPresent),
          now,
          createdAt,
          now,
        ],
      );

      for (final s in symbols) {
        database.execute(
          '''
          INSERT INTO symbols (id, file_id, name, kind, visibility, parent,
            signature, line, end_line, summary, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            _uuid.v4(),
            fileId,
            s.name,
            s.kind,
            s.visibility,
            s.parent,
            s.signature,
            s.line,
            s.endLine,
            s.summary,
            now,
          ],
        );
      }

      for (final imp in imports) {
        database.execute(
          'INSERT INTO imports (id, file_id, import_path, created_at) VALUES (?, ?, ?, ?)',
          [_uuid.v4(), fileId, imp, now],
        );
      }

      for (final ref in references) {
        database.execute(
          '''
          INSERT OR IGNORE INTO symbol_references (id, file_id, symbol, module,
            source_path, dot_path, symbol_kind, resolution, count, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            _uuid.v4(),
            fileId,
            ref.symbol,
            ref.module,
            ref.sourcePath,
            ref.dotPath,
            ref.symbolKind,
            ref.resolution,
            ref.count,
            now,
          ],
        );
      }

      for (final a in annotations) {
        database.execute(
          'INSERT INTO annotations (id, file_id, kind, message, line, created_at) VALUES (?, ?, ?, ?, ?, ?)',
          [_uuid.v4(), fileId, a['kind'], a['message'], a['line'], now],
        );
      }

      database.execute(
        '''
        INSERT INTO code_index_fts (file_id, path, name, summary, tags,
          symbol_names, symbol_summaries, reference_symbols)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          fileId,
          rec.path,
          rec.name,
          rec.summary ?? '',
          rec.tags.join(' '),
          symbols.map((s) => s.name).join(' '),
          symbols.map((s) => s.summary).whereType<String>().join(' '),
          references.map((r) => r.dotPath).join(' '),
        ],
      );
    });
  }

  /// Best-effort failure stamp on a file that already has a row (the failed
  /// write itself rolled back, §8.5.1).
  void _markFailed(String path, String error) {
    try {
      database.execute(
        "UPDATE files SET analysis_status = 'failed', analysis_error = ?, updated_at = ? WHERE path = ?",
        [error, DateTime.now().toUtc().toIso8601String(), path],
      );
    } catch (_) {
      // Nothing to stamp — the file was never indexed.
    }
  }
}
