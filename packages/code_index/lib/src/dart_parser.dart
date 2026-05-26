/// Dart source code parser using package:analyzer.
///
/// Provides syntactic (fast, unresolved) and resolved (slower, with external
/// symbol tracking) parsing modes.
library;

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

/// Result of parsing a Dart source file.
class DartParseResult {
  final List<String> imports;
  final List<Map<String, String?>> exports;
  final List<Map<String, String?>> variables;
  final List<Map<String, dynamic>> annotations;

  const DartParseResult({
    required this.imports,
    required this.exports,
    required this.variables,
    required this.annotations,
  });
}

/// An external symbol usage with dot-path notation.
class ExternalSymbolUsage {
  final String module;
  final String sourcePath;
  final String symbol;
  final String? symbolKind;
  final String dotPath;
  final int referenceCount;

  const ExternalSymbolUsage({
    required this.module,
    required this.sourcePath,
    required this.symbol,
    this.symbolKind,
    required this.dotPath,
    this.referenceCount = 1,
  });
}

/// Result of resolved analysis for a single file.
class ResolvedFileResult {
  final String filePath;
  final List<ExternalSymbolUsage> externalUsages;

  const ResolvedFileResult({
    required this.filePath,
    required this.externalUsages,
  });
}

// ── Comment annotation regexes (kept from original parser) ──────────────
final _commentAnnotationRegex = RegExp(
  r'//\s*(TODO|FIXME|HACK|NOTE)(?:\([^)]*\))?\s*:\s*(.*)',
  caseSensitive: false,
);
final _deprecatedRegex = RegExp(r'@[Dd]eprecated|@Deprecated\s*\(');

/// Parses Dart source code using package:analyzer for structural extraction.
///
/// [parse] provides a syntactic (unresolved) mode that is a drop-in
/// replacement for the previous regex-based parser.
class DartParser {
  /// Parse Dart [source] code syntactically and return structured metadata.
  ///
  /// Uses [parseString] from package:analyzer for a robust AST-based
  /// extraction of imports, declarations, class members, and annotations.
  static DartParseResult parse(String source) {
    final result = parseString(content: source, throwIfDiagnostics: false);
    final unit = result.unit;

    final imports = <String>[];
    final exports = <Map<String, String?>>[];
    final variables = <Map<String, String?>>[];

    // Extract imports from directives
    for (final directive in unit.directives) {
      if (directive is ImportDirective) {
        final uri = directive.uri.stringValue;
        if (uri != null) imports.add(uri);
      }
    }

    // Extract declarations
    for (final declaration in unit.declarations) {
      _processDeclaration(declaration, exports, variables);
    }

    // Extract annotations via regex (TODO/FIXME/HACK/NOTE + @deprecated)
    final annotations = _extractAnnotations(source);

    return DartParseResult(
      imports: imports,
      exports: exports,
      variables: variables,
      annotations: annotations,
    );
  }

  // ── Declaration processing ──────────────────────────────────────────

  static void _processDeclaration(
    Declaration decl,
    List<Map<String, String?>> exports,
    List<Map<String, String?>> variables,
  ) {
    if (decl is ClassDeclaration) {
      final name = decl.name.lexeme;
      if (name.startsWith('_')) return;
      final kind = decl.mixinKeyword != null ? 'mixin' : 'class';
      exports.add(_entry(name, kind));
      _processMembers(decl.members, exports, name);
    } else if (decl is EnumDeclaration) {
      final name = decl.name.lexeme;
      if (name.startsWith('_')) return;
      exports.add(_entry(name, 'enum'));
      _processMembers(decl.members, exports, name);
    } else if (decl is MixinDeclaration) {
      final name = decl.name.lexeme;
      if (name.startsWith('_')) return;
      exports.add(_entry(name, 'mixin'));
      _processMembers(decl.members, exports, name);
    } else if (decl
        is ExtensionTypeDeclaration) { // ignore: experimental_member_use
      final name = decl.name.lexeme;
      if (name.startsWith('_')) return;
      exports.add(_entry(name, 'extension'));
      _processMembers(decl.members, exports, name);
    } else if (decl is ExtensionDeclaration) {
      final nameToken = decl.name;
      if (nameToken == null) return;
      final name = nameToken.lexeme;
      if (name.startsWith('_')) return;
      exports.add(_entry(name, 'extension'));
      _processMembers(decl.members, exports, name);
    } else if (decl is GenericTypeAlias) {
      final name = decl.name.lexeme;
      if (!name.startsWith('_')) exports.add(_entry(name, 'typedef'));
    } else if (decl is FunctionTypeAlias) {
      final name = decl.name.lexeme;
      if (!name.startsWith('_')) exports.add(_entry(name, 'typedef'));
    } else if (decl is FunctionDeclaration) {
      final name = decl.name.lexeme;
      if (name.startsWith('_')) return;
      if (decl.isGetter) {
        variables.add({'name': name, 'description': null});
      } else if (!decl.isSetter) {
        final params = _paramsText(decl.functionExpression.parameters);
        exports.add(_entry(name, 'function', parameters: params));
      }
    } else if (decl is TopLevelVariableDeclaration) {
      for (final v in decl.variables.variables) {
        final name = v.name.lexeme;
        if (!name.startsWith('_')) {
          variables.add({'name': name, 'description': null});
        }
      }
    }
  }

  // ── Class / enum / mixin member processing ──────────────────────────

  static void _processMembers(
    NodeList<ClassMember> members,
    List<Map<String, String?>> exports,
    String className,
  ) {
    for (final member in members) {
      if (member is ConstructorDeclaration) {
        final nameToken = member.name;
        if (nameToken != null && nameToken.lexeme.startsWith('_')) continue;
        final ctorName =
            nameToken != null ? '$className.${nameToken.lexeme}' : className;
        final params = _paramsText(member.parameters);
        exports.add(
            _entry(ctorName, 'method', parameters: params, parent: className));
      } else if (member is MethodDeclaration) {
        final name = member.name.lexeme;
        if (name.startsWith('_')) continue;
        if (member.isOperator) {
          final params = _paramsText(member.parameters);
          exports.add(_entry('operator $name', 'method',
              parameters: params, parent: className));
        } else if (member.isGetter || member.isSetter) {
          exports.add(_entry(name, 'class_member', parent: className));
        } else {
          final params = _paramsText(member.parameters);
          exports.add(
              _entry(name, 'method', parameters: params, parent: className));
        }
      } else if (member is FieldDeclaration) {
        for (final v in member.fields.variables) {
          final name = v.name.lexeme;
          if (!name.startsWith('_')) {
            exports.add(_entry(name, 'class_member', parent: className));
          }
        }
      }
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  static Map<String, String?> _entry(
    String name,
    String kind, {
    String? parameters,
    String? parent,
  }) =>
      {
        'name': name,
        'kind': kind,
        'parameters': parameters,
        'description': null,
        'parent_name': parent,
      };

  static String? _paramsText(FormalParameterList? params) {
    if (params == null) return null;
    final src = params.toSource();
    return src.substring(1, src.length - 1).trim();
  }

  /// Extract comment annotations (TODO/FIXME/HACK/NOTE) and @deprecated.
  static List<Map<String, dynamic>> _extractAnnotations(String source) {
    final annotations = <Map<String, dynamic>>[];
    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trimLeft();
      final lineNumber = i + 1;

      final commentMatch = _commentAnnotationRegex.firstMatch(line);
      if (commentMatch != null) {
        annotations.add({
          'kind': commentMatch.group(1)!.toUpperCase(),
          'message': commentMatch.group(2)!.trim(),
          'line': lineNumber,
        });
        continue;
      }

      if (_deprecatedRegex.hasMatch(line)) {
        annotations.add({
          'kind': 'DEPRECATED',
          'message': null,
          'line': lineNumber,
        });
      }
    }
    return annotations;
  }
}

// ── Resolved mode: external symbol usages ─────────────────────────────

/// Resolved-mode parser for extracting external symbol usages with dot paths.
///
/// Uses [AnalysisContextCollection] to perform full name resolution, building
/// one context per project and reusing it across files.
class DartResolvedParser {
  /// Resolve external symbol usages for a batch of Dart files.
  ///
  /// [projectPath] is the absolute path to the project root (must contain
  /// `pubspec.yaml` and `.dart_tool/package_config.json`).
  /// [filePaths] are absolute paths to the Dart files to analyze.
  ///
  /// A single [AnalysisContextCollection] is built once; per-file resolution
  /// is cheap after that.
  static Future<List<ResolvedFileResult>> resolveExternalUsages({
    required String projectPath,
    required List<String> filePaths,
  }) async {
    final collection = AnalysisContextCollection(
      includedPaths: [projectPath],
    );

    final results = <ResolvedFileResult>[];
    for (final filePath in filePaths) {
      final context = collection.contextFor(filePath);
      final unitResult =
          await context.currentSession.getResolvedUnit(filePath);
      if (unitResult is! ResolvedUnitResult) continue;

      final currentLibrary = unitResult.libraryElement;
      final usageMap = <String, _UsageAccumulator>{};

      unitResult.unit.accept(_ExternalUsageVisitor(
        currentLibrary: currentLibrary,
        usageMap: usageMap,
      ));

      results.add(ResolvedFileResult(
        filePath: filePath,
        externalUsages: usageMap.values
            .map((a) => ExternalSymbolUsage(
                  module: a.module,
                  sourcePath: a.sourcePath,
                  symbol: a.symbol,
                  symbolKind: a.symbolKind,
                  dotPath: a.dotPath,
                  referenceCount: a.count,
                ))
            .toList(),
      ));
    }
    return results;
  }

  /// Parse a library URI into (module, sourcePath) components.
  ///
  /// Rules per §5a.3:
  /// - `package:foo/bar/baz.dart` → `('foo', 'bar.baz')`
  /// - `dart:io` → `('dart', 'io')`
  /// - `file:` or other → `('unknown', dotted-path)`
  static (String module, String sourcePath) parseLibraryUri(Uri uri) {
    final scheme = uri.scheme;
    if (scheme == 'package') {
      final path = uri.path; // foo/bar/baz.dart
      final slashIdx = path.indexOf('/');
      final module = path.substring(0, slashIdx);
      final rest = path.substring(slashIdx + 1);
      return (module, _pathToDotted(rest));
    } else if (scheme == 'dart') {
      return ('dart', uri.path);
    } else {
      return ('unknown', _pathToDotted(uri.path));
    }
  }

  /// Build a dot-path from module, source path, and symbol.
  static String buildDotPath(
          String module, String sourcePath, String symbol) =>
      '$module.$sourcePath.$symbol';

  static String _pathToDotted(String path) {
    var result = path;
    if (result.endsWith('.dart')) {
      result = result.substring(0, result.length - 5);
    }
    return result.replaceAll('/', '.');
  }
}

class _UsageAccumulator {
  final String module;
  final String sourcePath;
  final String symbol;
  final String? symbolKind;
  final String dotPath;
  int count = 1;

  _UsageAccumulator({
    required this.module,
    required this.sourcePath,
    required this.symbol,
    this.symbolKind,
    required this.dotPath,
  });
}
// ignore_for_file: deprecated_member_use
class _ExternalUsageVisitor extends RecursiveAstVisitor<void> {
  final LibraryElement currentLibrary;
  final Map<String, _UsageAccumulator> usageMap;

  _ExternalUsageVisitor({
    required this.currentLibrary,
    required this.usageMap,
  });

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    super.visitSimpleIdentifier(node);
    if (node.inDeclarationContext()) return;

    final element = node.staticElement;
    if (element == null) return;

    _recordIfExternal(element);
  }

  @override
  void visitNamedType(NamedType node) {
    super.visitNamedType(node);
    final element = node.element;
    if (element == null) return;

    _recordIfExternal(element);
  }

  void _recordIfExternal(Element element) {
    // For constructors, record the enclosing class instead
    var target = element;
    if (target is ConstructorElement) {
      target = target.enclosingElement3;
    }

    final lib = target.library;
    if (lib == null || lib == currentLibrary) return;

    var symbol = target.displayName;
    if (symbol.endsWith('=')) symbol = symbol.substring(0, symbol.length - 1);
    if (symbol.isEmpty) return;

    final uri = lib.source.uri;
    final (module, sourcePath) = DartResolvedParser.parseLibraryUri(uri);
    final dotPath =
        DartResolvedParser.buildDotPath(module, sourcePath, symbol);
    final kind = _elementKindString(target);

    usageMap.update(
      dotPath,
      (a) {
        a.count++;
        return a;
      },
      ifAbsent: () => _UsageAccumulator(
        module: module,
        sourcePath: sourcePath,
        symbol: symbol,
        symbolKind: kind,
        dotPath: dotPath,
      ),
    );
  }

  static String _elementKindString(Element e) {
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
        return 'method';
      default:
        return 'unknown';
    }
  }
}