/// Normalization of incoming `index-files` records (design §7.2).
///
/// Computes layer 0 (stat, SHA-256, line/word counts) for any file, derives
/// `layers_present`, clamps out-of-range symbol line ranges, and normalizes
/// agent-declared `references[]` into the canonical dot-path shape shared with
/// resolved Dart references. Pure apart from the single stat/read of the file
/// it is handed, so it is straightforward to unit-test.
library;

import 'dart:io';

import 'dart_extractor.dart';
import 'dot_path.dart';
import 'hash_utils.dart';

/// An agent-supplied structural symbol for a non-Dart file.
class RecordSymbol {
  final String name;
  final String kind;
  final String visibility;
  final String? parent;
  final String? signature;
  final int? line;
  final int? endLine;
  final String? summary;

  const RecordSymbol({
    required this.name,
    required this.kind,
    this.visibility = 'public',
    this.parent,
    this.signature,
    this.line,
    this.endLine,
    this.summary,
  });
}

/// The result of normalizing a single record: layer-0 facts plus the
/// non-Dart structural fields (ignored on the Dart route) and any warnings.
class NormalizedRecord {
  final String path;
  final String name;
  final String? fileType;
  final String? language;

  // Layer 0.
  final String fileHash;
  final int sizeBytes;
  final int lineCount;
  final int wordCount;
  final String mtime;

  // Layer 1 / tags.
  final String? summary;
  final List<String> tags;

  // Layer 3 — per-symbol descriptions keyed by `Name` or `Parent.name`.
  final Map<String, String> symbolSummaries;

  // Non-Dart structure (layer 2). Ignored for Dart records.
  final List<RecordSymbol> symbols;
  final List<String> imports;
  final List<SymbolReference> references;
  final List<Map<String, dynamic>> annotations;

  /// Whether the agent supplied any structural fields — drives layer-2
  /// presence for non-Dart files.
  final bool hasStructure;

  final List<String> warnings;

  const NormalizedRecord({
    required this.path,
    required this.name,
    required this.fileType,
    required this.language,
    required this.fileHash,
    required this.sizeBytes,
    required this.lineCount,
    required this.wordCount,
    required this.mtime,
    required this.summary,
    required this.tags,
    required this.symbolSummaries,
    required this.symbols,
    required this.imports,
    required this.references,
    required this.annotations,
    required this.hasStructure,
    required this.warnings,
  });
}

/// Compute layer 0 for [file] and, for non-Dart records, normalize the
/// agent-supplied structure in [record]. [relPath] is the project-relative
/// path stored in the DB; [file] is the resolved absolute file.
NormalizedRecord normalizeRecord({
  required Map<String, dynamic> record,
  required String relPath,
  required File file,
  required String name,
  required String? fileType,
}) {
  final warnings = <String>[];

  // ── Layer 0 ──────────────────────────────────────────────────────────
  final content = file.readAsStringSync();
  final stat = file.statSync();
  final lineCount = content.isEmpty ? 0 : content.split('\n').length;
  final wordCount = content
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .length;

  final summary = record['summary'] as String?;
  final language = record['language'] as String?;
  final tags =
      (record['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
      const <String>[];
  final symbolSummaries = <String, String>{};
  final rawSummaries = record['symbol_summaries'] as Map<String, dynamic>?;
  if (rawSummaries != null) {
    rawSummaries.forEach((k, v) {
      if (v != null) symbolSummaries[k] = v.toString();
    });
  }

  final rawSymbols = record['symbols'] as List<dynamic>?;
  final rawImports = record['imports'] as List<dynamic>?;
  final rawReferences = record['references'] as List<dynamic>?;
  final rawAnnotations = record['annotations'] as List<dynamic>?;
  final hasStructure =
      rawSymbols != null ||
      rawImports != null ||
      rawReferences != null ||
      rawAnnotations != null;

  // ── Non-Dart structure (clamped + normalized) ───────────────────────
  final symbols = <RecordSymbol>[];
  for (final raw in rawSymbols ?? const []) {
    final m = (raw as Map).cast<String, dynamic>();
    final sName = m['name']?.toString() ?? '';
    var line = (m['line'] as num?)?.toInt();
    var endLine = (m['end_line'] as num?)?.toInt();
    if (line != null && line > lineCount) {
      warnings.add(
        'line $line > line_count $lineCount; range cleared for symbol "$sName"',
      );
      line = null;
      endLine = null;
    } else if (endLine != null && endLine > lineCount) {
      warnings.add(
        'end_line $endLine > line_count $lineCount; range cleared for symbol "$sName"',
      );
      endLine = null;
    }
    symbols.add(
      RecordSymbol(
        name: sName,
        kind: m['kind']?.toString() ?? 'unknown',
        visibility: m['visibility']?.toString() ?? 'public',
        parent: m['parent']?.toString(),
        signature: m['signature']?.toString(),
        line: line,
        endLine: endLine,
        summary: m['summary']?.toString() ?? symbolSummaries[sName],
      ),
    );
  }

  final imports = (rawImports ?? const []).map((e) => e.toString()).toList();

  final references = <SymbolReference>[];
  for (final raw in rawReferences ?? const []) {
    final m = (raw as Map).cast<String, dynamic>();
    references.add(normalizeDeclaredReference(m));
  }

  final annotations = <Map<String, dynamic>>[];
  for (final raw in rawAnnotations ?? const []) {
    annotations.add((raw as Map).cast<String, dynamic>());
  }

  return NormalizedRecord(
    path: relPath,
    name: name,
    fileType: fileType,
    language: language,
    fileHash: computeFileHash(file),
    sizeBytes: stat.size,
    lineCount: lineCount,
    wordCount: wordCount,
    mtime: stat.modified.toUtc().toIso8601String(),
    summary: summary,
    tags: tags,
    symbolSummaries: symbolSummaries,
    symbols: symbols,
    imports: imports,
    references: references,
    annotations: annotations,
    hasStructure: hasStructure,
    warnings: warnings,
  );
}

/// Normalize an agent-declared reference `{symbol, qualifier, count}` into the
/// canonical dot-path shape with `resolution='declared'`.
///
/// - `qualifier` shaped like a library URI (`package:foo/bar.dart`, `dart:io`)
///   is parsed into `(module, source_path)`.
/// - A bare `qualifier` becomes the module → `<qualifier>.<symbol>`.
/// - A missing/blank qualifier collapses to `unknown.<symbol>`.
SymbolReference normalizeDeclaredReference(Map<String, dynamic> ref) {
  final symbol = ref['symbol']?.toString() ?? '';
  final qualifier = ref['qualifier']?.toString();
  final count = (ref['count'] as num?)?.toInt() ?? 1;

  String module;
  String sourcePath;
  if (qualifier == null || qualifier.trim().isEmpty) {
    module = 'unknown';
    sourcePath = '';
  } else if (qualifier.contains(':') || qualifier.contains('/')) {
    final parsed = parseLibraryUriString(qualifier);
    module = parsed.$1;
    sourcePath = parsed.$2;
  } else {
    module = qualifier;
    sourcePath = '';
  }

  return SymbolReference(
    symbol: symbol,
    module: module,
    sourcePath: sourcePath,
    dotPath: buildDotPath(module, sourcePath, symbol),
    resolution: 'declared',
    count: count,
  );
}

/// Derive `layers_present` from what a write actually produced.
///
/// Layer 0 is always present. Layer 1 when a summary exists, layer 2 when
/// structure was computed (always true for Dart), layer 3 when any per-symbol
/// summary was supplied.
List<int> deriveLayersPresent({
  required bool hasSummary,
  required bool hasStructure,
  required bool hasSymbolSummaries,
}) {
  return [0, if (hasSummary) 1, if (hasStructure) 2, if (hasSymbolSummaries) 3];
}
