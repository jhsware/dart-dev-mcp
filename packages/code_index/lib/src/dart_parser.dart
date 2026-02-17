/// Dart source code parser for automated metadata extraction.
///
/// Extracts imports, exports (classes, enums, mixins, extensions, typedefs,
/// functions, methods, class members), variables, and annotations from
/// Dart source code using regex and brace-counting — no analyzer dependency.

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

/// Parses Dart source code and extracts structural metadata.
///
/// Uses regex matching and brace-depth tracking to identify declarations
/// at the top level and within class bodies. Private members (names
/// starting with `_`) are excluded.
class DartParser {
  // ── Import regex ──────────────────────────────────────────────────────
  static final _importRegex =
      RegExp(r'''^\s*import\s+['"]([^'"]+)['"]\s*[^;]*;''', multiLine: true);

  // ── Annotation regexes ────────────────────────────────────────────────
  static final _commentAnnotationRegex = RegExp(
    r'//\s*(TODO|FIXME|HACK|NOTE)(?:\([^)]*\))?\s*:\s*(.*)',
    caseSensitive: false,
  );
  static final _deprecatedRegex = RegExp(
    r'@[Dd]eprecated|@Deprecated\s*\(',
  );

  // ── Declaration regexes (applied to trimmed lines) ────────────────────
  static final _classRegex = RegExp(
    r'^(?:abstract\s+|sealed\s+|base\s+|final\s+|interface\s+)*class\s+(\w+)',
  );
  static final _enumRegex = RegExp(r'^enum\s+(\w+)');
  static final _mixinRegex = RegExp(r'^(?:base\s+)?mixin\s+(?:class\s+)?(\w+)');
  static final _extensionRegex =
      RegExp(r'^extension\s+(\w+)\s+on\s+');
  static final _extensionTypeRegex =
      RegExp(r'^(?:final\s+|base\s+|interface\s+)*extension\s+type\s+(\w+)');
  static final _typedefRegex = RegExp(r'^typedef\s+(\w+)');

  // Top-level variable patterns
  static final _constFinalVarRegex = RegExp(
    r'^(?:late\s+)?(?:const|final|var)\s+(?:[\w<>,\s?]+\s+)?(\w+)\s*[=;]',
  );
  static final _typedVarRegex = RegExp(
    r'^([\w<>,?]+)\s+(\w+)\s*=',
  );

  // Getter / setter
  static final _getterRegex = RegExp(
    r'^(?:static\s+)?(?:[\w<>,?\s]+\s+)?get\s+(\w+)',
  );
  static final _setterRegex = RegExp(
    r'^(?:static\s+)?set\s+(\w+)\s*\(',
  );

  // Function / method (careful to exclude keywords)
  static final _controlKeywords = {
    'if', 'for', 'while', 'switch', 'catch', 'return', 'else', 'do', 'try',
    'throw', 'assert', 'await', 'yield', 'break', 'continue', 'new', 'super',
    'this',
  };

  // Factory / named constructor
  static final _factoryRegex = RegExp(
    r'^factory\s+([\w.]+)\s*[<(]',
  );
  static final _namedConstructorRegex = RegExp(
    r'^(\w+)\.(\w+)\s*\(',
  );

  // Operator overload
  static final _operatorRegex = RegExp(
    r'^(?:[\w<>,?\s]+\s+)?operator\s+(\S+)\s*\(',
  );

  // General function/method: return-type name(
  static final _functionRegex = RegExp(
    r'^(?:static\s+)?(?:[\w<>,?\s]+\s+)(\w+)\s*[<(]',
  );

  // Field declaration inside a class body
  static final _fieldRegex = RegExp(
    r'^(?:static\s+)?(?:late\s+)?(?:final\s+|const\s+|var\s+)?(?:[\w<>,?]+\s+)(\w+)\s*[=;]',
  );

  /// Parse Dart [source] code and return structured metadata.
  static DartParseResult parse(String source) {
    final imports = _extractImports(source);
    final annotations = <Map<String, dynamic>>[];
    final exports = <Map<String, String?>>[];
    final variables = <Map<String, String?>>[];

    final lines = source.split('\n');
    var braceDepth = 0;
    String? currentClassName;
    var inBlockComment = false;
    var inString = false;

    for (var i = 0; i < lines.length; i++) {
      final lineNumber = i + 1;
      final rawLine = lines[i];
      final trimmed = rawLine.trimLeft();

      // ── Annotations (scan regardless of depth) ──────────────────────
      _extractAnnotations(trimmed, lineNumber, annotations);

      // ── Process braces and declarations ─────────────────────────────
      // We need to handle strings and comments to avoid false brace counts
      var j = 0;
      final chars = rawLine.codeUnits;
      var declarationProcessed = false;

      while (j < chars.length) {
        final ch = rawLine[j];

        // Handle block comments
        if (inBlockComment) {
          if (ch == '*' && j + 1 < chars.length && rawLine[j + 1] == '/') {
            inBlockComment = false;
            j += 2;
            continue;
          }
          j++;
          continue;
        }

        // Start of block comment
        if (ch == '/' && j + 1 < chars.length && rawLine[j + 1] == '*') {
          inBlockComment = true;
          j += 2;
          continue;
        }

        // Line comment — skip rest of line
        if (ch == '/' && j + 1 < chars.length && rawLine[j + 1] == '/') {
          break;
        }

        // String literals — skip contents
        if (ch == "'" || ch == '"') {
          // Check for triple quotes
          final isTriple = j + 2 < chars.length &&
              rawLine[j + 1] == ch &&
              rawLine[j + 2] == ch;
          if (isTriple) {
            // Find matching triple-quote on this line or skip to end
            final endIdx = rawLine.indexOf(ch * 3, j + 3);
            if (endIdx >= 0) {
              j = endIdx + 3;
            } else {
              // Multi-line string — skip rest of line
              // We'll simplify by not tracking multi-line strings across lines
              // since brace counting in string literals is an edge case
              break;
            }
            continue;
          }
          // Single-line string — skip to matching quote
          j++;
          while (j < chars.length) {
            if (rawLine[j] == '\\') {
              j += 2; // skip escaped char
              continue;
            }
            if (rawLine[j] == ch) {
              j++;
              break;
            }
            j++;
          }
          continue;
        }

        // Brace counting
        if (ch == '{') {
          if (!declarationProcessed && braceDepth == 0) {
            // Try to match a declaration on this line BEFORE incrementing depth
            _processTopLevelDeclaration(
                trimmed, exports, variables, currentClassName);
            declarationProcessed = true;
            // If we matched a class-like declaration, set currentClassName
            final className = _matchClassName(trimmed);
            if (className != null) {
              currentClassName = className;
            }
          }
          braceDepth++;
        } else if (ch == '}') {
          braceDepth--;
          if (braceDepth == 0) {
            currentClassName = null;
          }
        }
        j++;
      }

      // Process declarations for lines that don't contain braces
      if (!declarationProcessed) {
        if (braceDepth == 0) {
          _processTopLevelDeclaration(
              trimmed, exports, variables, currentClassName);
          // Check if this line starts a class-like declaration (body may be on next line)
          final className = _matchClassName(trimmed);
          if (className != null) {
            currentClassName = className;
          }
        } else if (braceDepth == 1 && currentClassName != null) {
          _processClassMember(trimmed, exports, currentClassName);
        }
      } else if (braceDepth == 1 && currentClassName != null && !_isClassLikeDeclaration(trimmed)) {
        // The line had a brace but was inside a class body (e.g., method with body on same line)
        // We already processed it as top-level if braceDepth was 0 when we hit the brace
      }
    }

    return DartParseResult(
      imports: imports,
      exports: exports,
      variables: variables,
      annotations: annotations,
    );
  }

  /// Extract all import paths from source.
  static List<String> _extractImports(String source) {
    return _importRegex
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toList();
  }

  /// Extract annotations from a single line.
  static void _extractAnnotations(
    String trimmedLine,
    int lineNumber,
    List<Map<String, dynamic>> annotations,
  ) {
    // Comment-style annotations
    final commentMatch = _commentAnnotationRegex.firstMatch(trimmedLine);
    if (commentMatch != null) {
      annotations.add({
        'kind': commentMatch.group(1)!.toUpperCase(),
        'message': commentMatch.group(2)!.trim(),
        'line': lineNumber,
      });
      return;
    }

    // @deprecated / @Deprecated
    if (_deprecatedRegex.hasMatch(trimmedLine)) {
      annotations.add({
        'kind': 'DEPRECATED',
        'message': null,
        'line': lineNumber,
      });
    }
  }

  /// Check if a trimmed line starts a class-like declaration and return the name.
  static String? _matchClassName(String trimmed) {
    // Extension type before extension (more specific first)
    var m = _extensionTypeRegex.firstMatch(trimmed);
    if (m != null) return m.group(1);

    m = _classRegex.firstMatch(trimmed);
    if (m != null) return m.group(1);

    m = _enumRegex.firstMatch(trimmed);
    if (m != null) return m.group(1);

    m = _mixinRegex.firstMatch(trimmed);
    if (m != null) return m.group(1);

    m = _extensionRegex.firstMatch(trimmed);
    if (m != null) return m.group(1);

    return null;
  }

  /// Whether this line is a class/enum/mixin/extension declaration.
  static bool _isClassLikeDeclaration(String trimmed) {
    return _classRegex.hasMatch(trimmed) ||
        _enumRegex.hasMatch(trimmed) ||
        _mixinRegex.hasMatch(trimmed) ||
        _extensionRegex.hasMatch(trimmed) ||
        _extensionTypeRegex.hasMatch(trimmed);
  }

  /// Process a top-level line (braceDepth == 0).
  static void _processTopLevelDeclaration(
    String trimmed,
    List<Map<String, String?>> exports,
    List<Map<String, String?>> variables,
    String? currentClassName,
  ) {
    if (trimmed.isEmpty || trimmed.startsWith('//') || trimmed.startsWith('/*')
        || trimmed.startsWith('*') || trimmed.startsWith('import ')
        || trimmed.startsWith('export ') || trimmed.startsWith('part ')
        || trimmed.startsWith('library ') || trimmed.startsWith('}')) {
      return;
    }

    // Class declarations
    final classMatch = _classRegex.firstMatch(trimmed);
    if (classMatch != null) {
      final name = classMatch.group(1)!;
      if (!name.startsWith('_')) {
        exports.add({'name': name, 'kind': 'class', 'parameters': null, 'description': null, 'parent_name': null});
      }
      return;
    }

    // Enum declarations
    final enumMatch = _enumRegex.firstMatch(trimmed);
    if (enumMatch != null) {
      final name = enumMatch.group(1)!;
      if (!name.startsWith('_')) {
        exports.add({'name': name, 'kind': 'enum', 'parameters': null, 'description': null, 'parent_name': null});
      }
      return;
    }

    // Extension type (must check before extension)
    final extTypeMatch = _extensionTypeRegex.firstMatch(trimmed);
    if (extTypeMatch != null) {
      final name = extTypeMatch.group(1)!;
      if (!name.startsWith('_')) {
        exports.add({'name': name, 'kind': 'extension', 'parameters': null, 'description': null, 'parent_name': null});
      }
      return;
    }

    // Mixin declarations (check before extension since "mixin class" contains "class")
    final mixinMatch = _mixinRegex.firstMatch(trimmed);
    if (mixinMatch != null && !_classRegex.hasMatch(trimmed)) {
      final name = mixinMatch.group(1)!;
      if (!name.startsWith('_')) {
        exports.add({'name': name, 'kind': 'mixin', 'parameters': null, 'description': null, 'parent_name': null});
      }
      return;
    }

    // Extension declarations
    final extMatch = _extensionRegex.firstMatch(trimmed);
    if (extMatch != null) {
      final name = extMatch.group(1)!;
      if (!name.startsWith('_')) {
        exports.add({'name': name, 'kind': 'extension', 'parameters': null, 'description': null, 'parent_name': null});
      }
      return;
    }

    // Typedef declarations
    final typedefMatch = _typedefRegex.firstMatch(trimmed);
    if (typedefMatch != null) {
      final name = typedefMatch.group(1)!;
      if (!name.startsWith('_')) {
        exports.add({'name': name, 'kind': 'typedef', 'parameters': null, 'description': null, 'parent_name': null});
      }
      return;
    }

    // Top-level functions
    if (_tryMatchFunction(trimmed, exports, null)) return;

    // Top-level getters
    final getterMatch = _getterRegex.firstMatch(trimmed);
    if (getterMatch != null) {
      final name = getterMatch.group(1)!;
      if (!name.startsWith('_') && !_controlKeywords.contains(name)) {
        variables.add({'name': name, 'description': null});
      }
      return;
    }

    // Top-level variables/constants
    if (_tryMatchVariable(trimmed, variables)) return;
  }

  /// Process a class member (braceDepth == 1).
  static void _processClassMember(
    String trimmed,
    List<Map<String, String?>> exports,
    String className,
  ) {
    if (trimmed.isEmpty || trimmed.startsWith('//') || trimmed.startsWith('/*')
        || trimmed.startsWith('*') || trimmed.startsWith('}')
        || trimmed.startsWith('@')) {
      return;
    }

    // Operator overloads
    final opMatch = _operatorRegex.firstMatch(trimmed);
    if (opMatch != null) {
      final op = 'operator ${opMatch.group(1)!}';
      final params = _extractParams(trimmed);
      exports.add({
        'name': op,
        'kind': 'method',
        'parameters': params,
        'description': null,
        'parent_name': className,
      });
      return;
    }

    // Factory constructors
    final factoryMatch = _factoryRegex.firstMatch(trimmed);
    if (factoryMatch != null) {
      final fullName = factoryMatch.group(1)!;
      final params = _extractParams(trimmed);
      exports.add({
        'name': fullName,
        'kind': 'method',
        'parameters': params,
        'description': null,
        'parent_name': className,
      });
      return;
    }

    // Named constructors: ClassName.name(
    final namedCtorMatch = _namedConstructorRegex.firstMatch(trimmed);
    if (namedCtorMatch != null) {
      final ctorClassName = namedCtorMatch.group(1)!;
      final ctorName = namedCtorMatch.group(2)!;
      if (ctorClassName == className && !ctorName.startsWith('_')) {
        final params = _extractParams(trimmed);
        exports.add({
          'name': '$className.$ctorName',
          'kind': 'method',
          'parameters': params,
          'description': null,
          'parent_name': className,
        });
        return;
      }
    }

    // Getters
    final getterMatch = _getterRegex.firstMatch(trimmed);
    if (getterMatch != null) {
      final name = getterMatch.group(1)!;
      if (!name.startsWith('_')) {
        exports.add({
          'name': name,
          'kind': 'class_member',
          'parameters': null,
          'description': null,
          'parent_name': className,
        });
      }
      return;
    }

    // Setters
    final setterMatch = _setterRegex.firstMatch(trimmed);
    if (setterMatch != null) {
      final name = setterMatch.group(1)!;
      if (!name.startsWith('_')) {
        exports.add({
          'name': name,
          'kind': 'class_member',
          'parameters': null,
          'description': null,
          'parent_name': className,
        });
      }
      return;
    }

    // Methods (including regular constructors matching className)
    if (_tryMatchFunction(trimmed, exports, className)) return;

    // Fields
    _tryMatchField(trimmed, exports, className);
  }

  /// Try to match a function/method declaration. Returns true if matched.
  static bool _tryMatchFunction(
    String trimmed,
    List<Map<String, String?>> exports,
    String? className,
  ) {
    // Check for constructor (className followed by parenthesis)
    if (className != null) {
      final ctorPattern = RegExp('^$className\\s*\\(');
      if (ctorPattern.hasMatch(trimmed)) {
        final params = _extractParams(trimmed);
        exports.add({
          'name': className,
          'kind': 'method',
          'parameters': params,
          'description': null,
          'parent_name': className,
        });
        return true;
      }
    }

    final match = _functionRegex.firstMatch(trimmed);
    if (match != null) {
      final name = match.group(1)!;
      if (name.startsWith('_') || _controlKeywords.contains(name)) {
        return false;
      }

      final params = _extractParams(trimmed);
      final kind = className != null ? 'method' : 'function';
      exports.add({
        'name': name,
        'kind': kind,
        'parameters': params,
        'description': null,
        'parent_name': className,
      });
      return true;
    }
    return false;
  }

  /// Try to match a top-level variable declaration. Returns true if matched.
  static bool _tryMatchVariable(
    String trimmed,
    List<Map<String, String?>> variables,
  ) {
    final constFinalMatch = _constFinalVarRegex.firstMatch(trimmed);
    if (constFinalMatch != null) {
      final name = constFinalMatch.group(1)!;
      if (!name.startsWith('_')) {
        variables.add({'name': name, 'description': null});
        return true;
      }
    }

    // Typed variable: `Type name =`
    final typedMatch = _typedVarRegex.firstMatch(trimmed);
    if (typedMatch != null) {
      final typeName = typedMatch.group(1)!;
      final name = typedMatch.group(2)!;
      // Exclude if the "type" looks like a keyword or function call
      if (!name.startsWith('_') &&
          !_controlKeywords.contains(typeName) &&
          !_controlKeywords.contains(name) &&
          typeName[0] == typeName[0].toUpperCase()) {
        variables.add({'name': name, 'description': null});
        return true;
      }
    }
    return false;
  }

  /// Try to match a field declaration inside a class. Returns true if matched.
  static bool _tryMatchField(
    String trimmed,
    List<Map<String, String?>> exports,
    String className,
  ) {
    final match = _fieldRegex.firstMatch(trimmed);
    if (match != null) {
      final name = match.group(1)!;
      if (!name.startsWith('_') && !_controlKeywords.contains(name)) {
        exports.add({
          'name': name,
          'kind': 'class_member',
          'parameters': null,
          'description': null,
          'parent_name': className,
        });
        return true;
      }
    }
    return false;
  }

  /// Extract parameter string from a line containing parentheses.
  static String? _extractParams(String line) {
    final openIdx = line.indexOf('(');
    if (openIdx < 0) return null;

    var depth = 0;
    var i = openIdx;
    while (i < line.length) {
      if (line[i] == '(') {
        depth++;
      } else if (line[i] == ')') {
        depth--;
        if (depth == 0) {
          return line.substring(openIdx + 1, i).trim();
        }
      }
      i++;
    }
    // If closing paren not found on this line, return what we have
    return line.substring(openIdx + 1).trim();
  }
}
