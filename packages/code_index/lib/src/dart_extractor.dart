/// Dart layer-2 extractor built on `package:analyzer`.
///
/// Produces declarations with exact 1-indexed line ranges + visibility,
/// resolved external references as canonical dot-paths, and regex annotations.
///
/// A single [AnalysisContextCollection] is kept warm per project per process
/// and updated incrementally via [DartExtractor.notifyChanged] — v1 rebuilt
/// the collection on every call, which was the dominant cost of `auto-index`.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';

import 'dot_path.dart';

// ── Result model ────────────────────────────────────────────────────────

/// A single extracted declaration.
class ExtractedSymbol {
  final String name;

  /// Design §6 kind vocabulary: class, mixin, enum, function, method,
  /// constructor, getter, setter, variable, constant, typedef, extension.
  final String kind;

  /// `public` or `private` (`_`-prefixed names are private).
  final String visibility;

  /// Enclosing declaration name, or `null` for top-level symbols.
  final String? parent;

  /// Compact parameter signature (parameter list text), or `null`.
  final String? signature;

  /// 1-indexed inclusive line range spanning the declaration.
  final int line;
  final int endLine;

  const ExtractedSymbol({
    required this.name,
    required this.kind,
    required this.visibility,
    this.parent,
    this.signature,
    required this.line,
    required this.endLine,
  });

  bool get isPrivate => visibility == 'private';
}

/// A resolved (or declared) external symbol reference in dot-path form.
class SymbolReference {
  final String symbol;
  final String module;
  final String sourcePath;
  final String dotPath;
  final String? symbolKind;

  /// `resolved` (analyzer) or `declared` (agent best-effort).
  final String resolution;
  final int count;

  const SymbolReference({
    required this.symbol,
    required this.module,
    required this.sourcePath,
    required this.dotPath,
    this.symbolKind,
    this.resolution = 'resolved',
    this.count = 1,
  });
}

/// Everything extracted from a single Dart file.
class ExtractedFile {
  final List<ExtractedSymbol> symbols;
  final List<String> imports;
  final List<SymbolReference> references;
  final List<Map<String, dynamic>> annotations;

  const ExtractedFile({
    required this.symbols,
    required this.imports,
    required this.references,
    required this.annotations,
  });

  static const empty = ExtractedFile(
    symbols: [],
    imports: [],
    references: [],
    annotations: [],
  );
}

// ── Annotation regexes ──────────────────────────────────────────────────

final _commentAnnotationRegex = RegExp(
  r'//\s*(TODO|FIXME|HACK|NOTE)(?:\([^)]*\))?\s*:\s*(.*)',
  caseSensitive: false,
);
final _deprecatedRegex = RegExp(r'@[Dd]eprecated');

// ── Extractor ───────────────────────────────────────────────────────────

/// Extracts Dart structure from a warm, incrementally-updated analysis
/// context rooted at [projectPath].
class DartExtractor {
  DartExtractor({required this.projectPath});

  /// Absolute path to the project root (must contain `pubspec.yaml` and a
  /// resolved `.dart_tool/package_config.json` for resolved references).
  final String projectPath;

  AnalysisContextCollection? _collection;

  AnalysisContextCollection get _contexts =>
      _collection ??= AnalysisContextCollection(includedPaths: [projectPath]);

  /// Fully extract [absolutePath]: declarations (line ranges + visibility),
  /// imports, resolved references, and annotations.
  ///
  /// Falls back to a syntactic-only result if resolution is unavailable, so a
  /// missing `package_config.json` never loses declarations.
  Future<ExtractedFile> extractFile(String absolutePath) async {
    final context = _contexts.contextFor(absolutePath);
    final unitResult =
        await context.currentSession.getResolvedUnit(absolutePath);

    if (unitResult is! ResolvedUnitResult) {
      final source = File(absolutePath).existsSync()
          ? File(absolutePath).readAsStringSync()
          : '';
      return extractSyntactic(source);
    }

    final unit = unitResult.unit;
    final lineInfo = unitResult.lineInfo;
    return ExtractedFile(
      symbols: _symbolsFromUnit(unit, lineInfo),
      imports: _importsFromUnit(unit),
      references: _resolvedReferences(unitResult),
      annotations: extractAnnotations(unitResult.content),
    );
  }

  /// Notify the warm context that [absolutePath] changed and apply the change
  /// incrementally — no full collection rebuild.
  Future<void> notifyChanged(String absolutePath) async {
    final context = _contexts.contextFor(absolutePath);
    context.changeFile(absolutePath);
    await context.applyPendingFileChanges();
  }

  /// Syntactic-only extraction from raw [source]; no resolution, so
  /// [ExtractedFile.references] is always empty. Fast and context-free —
  /// useful for unit tests and non-resolvable snippets.
  static ExtractedFile extractSyntactic(String source) {
    final unit = parseString(content: source, throwIfDiagnostics: false).unit;
    return ExtractedFile(
      symbols: _symbolsFromUnit(unit, unit.lineInfo),
      imports: _importsFromUnit(unit),
      references: const [],
      annotations: extractAnnotations(source),
    );
  }

  // ── Declarations ──────────────────────────────────────────────────────

  static List<ExtractedSymbol> _symbolsFromUnit(
    CompilationUnit unit,
    LineInfo lineInfo,
  ) {
    final symbols = <ExtractedSymbol>[];
    for (final decl in unit.declarations) {
      _processDeclaration(decl, lineInfo, symbols);
    }
    return symbols;
  }

  static void _processDeclaration(
    CompilationUnitMember decl,
    LineInfo lineInfo,
    List<ExtractedSymbol> out,
  ) {
    if (decl is ClassDeclaration) {
      out.add(_symbol(decl.name.lexeme, 'class', lineInfo, decl));
      _processMembers(decl.members, decl.name.lexeme, lineInfo, out);
    } else if (decl is EnumDeclaration) {
      out.add(_symbol(decl.name.lexeme, 'enum', lineInfo, decl));
      _processMembers(decl.members, decl.name.lexeme, lineInfo, out);
    } else if (decl is MixinDeclaration) {
      out.add(_symbol(decl.name.lexeme, 'mixin', lineInfo, decl));
      _processMembers(decl.members, decl.name.lexeme, lineInfo, out);
      // ignore: experimental_member_use
    } else if (decl is ExtensionTypeDeclaration) {
      out.add(_symbol(decl.name.lexeme, 'extension', lineInfo, decl));
      _processMembers(decl.members, decl.name.lexeme, lineInfo, out);
    } else if (decl is ExtensionDeclaration) {
      final nameToken = decl.name;
      if (nameToken == null) return; // unnamed extension
      out.add(_symbol(nameToken.lexeme, 'extension', lineInfo, decl));
      _processMembers(decl.members, nameToken.lexeme, lineInfo, out);
    } else if (decl is GenericTypeAlias) {
      out.add(_symbol(decl.name.lexeme, 'typedef', lineInfo, decl));
    } else if (decl is FunctionTypeAlias) {
      out.add(_symbol(decl.name.lexeme, 'typedef', lineInfo, decl));
    } else if (decl is FunctionDeclaration) {
      final name = decl.name.lexeme;
      final kind = decl.isGetter
          ? 'getter'
          : decl.isSetter
              ? 'setter'
              : 'function';
      final sig = decl.isGetter || decl.isSetter
          ? null
          : _paramsText(decl.functionExpression.parameters);
      out.add(_symbol(name, kind, lineInfo, decl, signature: sig));
    } else if (decl is TopLevelVariableDeclaration) {
      final kind = decl.variables.isConst ? 'constant' : 'variable';
      for (final v in decl.variables.variables) {
        out.add(_symbol(v.name.lexeme, kind, lineInfo, decl));
      }
    }
  }

  static void _processMembers(
    NodeList<ClassMember> members,
    String parent,
    LineInfo lineInfo,
    List<ExtractedSymbol> out,
  ) {
    for (final member in members) {
      if (member is ConstructorDeclaration) {
        final nameToken = member.name;
        final name =
            nameToken != null ? '$parent.${nameToken.lexeme}' : parent;
        out.add(_symbol(name, 'constructor', lineInfo, member,
            parent: parent, signature: _paramsText(member.parameters)));
      } else if (member is MethodDeclaration) {
        final name = member.name.lexeme;
        if (member.isOperator) {
          out.add(_symbol('operator $name', 'method', lineInfo, member,
              parent: parent, signature: _paramsText(member.parameters)));
        } else if (member.isGetter) {
          out.add(_symbol(name, 'getter', lineInfo, member, parent: parent));
        } else if (member.isSetter) {
          out.add(_symbol(name, 'setter', lineInfo, member, parent: parent));
        } else {
          out.add(_symbol(name, 'method', lineInfo, member,
              parent: parent, signature: _paramsText(member.parameters)));
        }
      } else if (member is FieldDeclaration) {
        final kind = member.fields.isConst ? 'constant' : 'variable';
        for (final v in member.fields.variables) {
          out.add(_symbol(v.name.lexeme, kind, lineInfo, member,
              parent: parent));
        }
      }
    }
  }

  static ExtractedSymbol _symbol(
    String name,
    String kind,
    LineInfo lineInfo,
    AstNode node, {
    String? parent,
    String? signature,
  }) {
    final start = lineInfo.getLocation(node.offset).lineNumber;
    final end = lineInfo.getLocation(node.end).lineNumber;
    // Visibility keys off the trailing identifier (e.g. `Foo.named` → `named`).
    final last = name.contains('.') ? name.split('.').last : name;
    return ExtractedSymbol(
      name: name,
      kind: kind,
      visibility: last.startsWith('_') ? 'private' : 'public',
      parent: parent,
      signature: signature,
      line: start,
      endLine: end,
    );
  }

  static String? _paramsText(FormalParameterList? params) {
    if (params == null) return null;
    final src = params.toSource();
    return src.substring(1, src.length - 1).trim();
  }

  static List<String> _importsFromUnit(CompilationUnit unit) {
    final imports = <String>[];
    for (final directive in unit.directives) {
      if (directive is ImportDirective) {
        final uri = directive.uri.stringValue;
        if (uri != null) imports.add(uri);
      }
    }
    return imports;
  }

  // ── Resolved references ───────────────────────────────────────────────

  static List<SymbolReference> _resolvedReferences(ResolvedUnitResult result) {
    final acc = <String, _RefAccumulator>{};
    result.unit.accept(_ReferenceVisitor(
      currentLibrary: result.libraryElement,
      acc: acc,
    ));
    return acc.values
        .map((a) => SymbolReference(
              symbol: a.symbol,
              module: a.module,
              sourcePath: a.sourcePath,
              dotPath: a.dotPath,
              symbolKind: a.symbolKind,
              resolution: 'resolved',
              count: a.count,
            ))
        .toList();
  }

  // ── Annotations ───────────────────────────────────────────────────────

  /// Extract `TODO`/`FIXME`/`HACK`/`NOTE`/`DEPRECATED` annotations with
  /// 1-indexed line numbers from raw [source].
  static List<Map<String, dynamic>> extractAnnotations(String source) {
    final annotations = <Map<String, dynamic>>[];
    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trimLeft();
      final match = _commentAnnotationRegex.firstMatch(line);
      if (match != null) {
        annotations.add({
          'kind': match.group(1)!.toUpperCase(),
          'message': match.group(2)!.trim(),
          'line': i + 1,
        });
        continue;
      }
      if (_deprecatedRegex.hasMatch(line)) {
        annotations.add({'kind': 'DEPRECATED', 'message': null, 'line': i + 1});
      }
    }
    return annotations;
  }
}

// ── Resolved reference visitor ──────────────────────────────────────────

class _RefAccumulator {
  final String symbol;
  final String module;
  final String sourcePath;
  final String dotPath;
  final String? symbolKind;
  int count = 1;

  _RefAccumulator({
    required this.symbol,
    required this.module,
    required this.sourcePath,
    required this.dotPath,
    this.symbolKind,
  });
}

// ignore_for_file: deprecated_member_use
class _ReferenceVisitor extends RecursiveAstVisitor<void> {
  final LibraryElement currentLibrary;
  final Map<String, _RefAccumulator> acc;

  _ReferenceVisitor({required this.currentLibrary, required this.acc});

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    super.visitSimpleIdentifier(node);
    if (node.inDeclarationContext()) return;
    final element = node.staticElement;
    if (element != null) _record(element);
  }

  @override
  void visitNamedType(NamedType node) {
    super.visitNamedType(node);
    final element = node.element;
    if (element != null) _record(element);
  }

  void _record(Element element) {
    // Attribute constructors to their enclosing class.
    var target = element;
    if (target is ConstructorElement) {
      target = target.enclosingElement3;
    }

    // The defining library is the source of truth — this makes re-exports and
    // prefixed/`show`/`hide` imports resolve to where the symbol is declared.
    final lib = target.library;
    if (lib == null || lib == currentLibrary) return;

    var symbol = target.displayName;
    if (symbol.endsWith('=')) symbol = symbol.substring(0, symbol.length - 1);
    if (symbol.isEmpty) return;

    final (module, sourcePath) = parseLibraryUri(lib.source.uri);
    final dotPath = buildDotPath(module, sourcePath, symbol);

    final existing = acc[dotPath];
    if (existing != null) {
      existing.count++;
      return;
    }
    acc[dotPath] = _RefAccumulator(
      symbol: symbol,
      module: module,
      sourcePath: sourcePath,
      dotPath: dotPath,
      symbolKind: _elementKind(target),
    );
  }

  static String _elementKind(Element e) {
    switch (e.kind) {
      case ElementKind.CLASS:
        return 'class';
      case ElementKind.FUNCTION:
        return 'function';
      case ElementKind.METHOD:
        return 'method';
      case ElementKind.ENUM:
        return 'enum';
      case ElementKind.MIXIN:
        return 'mixin';
      case ElementKind.EXTENSION:
        return 'extension';
      case ElementKind.TYPE_ALIAS:
        return 'typedef';
      case ElementKind.TOP_LEVEL_VARIABLE:
      case ElementKind.FIELD:
      case ElementKind.GETTER:
      case ElementKind.SETTER:
        return 'variable';
      case ElementKind.CONSTRUCTOR:
        return 'constructor';
      default:
        return 'unknown';
    }
  }
}
