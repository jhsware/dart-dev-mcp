import 'dart:io';

import 'package:jhsware_code_code_index/code_index_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('dot_path canonicalization', () {
    test('package: URI → module.source_path', () {
      final (module, src) = parseLibraryUri(
        Uri.parse('package:flutter/material.dart'),
      );
      expect(module, 'flutter');
      expect(src, 'material');
      expect(buildDotPath(module, src, 'Widget'), 'flutter.material.Widget');
    });

    test('package: URI with nested path', () {
      final (module, src) = parseLibraryUri(
        Uri.parse('package:flutter/src/widgets/framework.dart'),
      );
      expect(module, 'flutter');
      expect(src, 'src.widgets.framework');
      expect(
        buildDotPath(module, src, 'Widget'),
        'flutter.src.widgets.framework.Widget',
      );
    });

    test('single-file package library', () {
      final (module, src) = parseLibraryUri(
        Uri.parse('package:path/path.dart'),
      );
      expect(module, 'path');
      expect(src, 'path');
    });

    test('dart: URI', () {
      final (module, src) = parseLibraryUri(Uri.parse('dart:io'));
      expect(module, 'dart');
      expect(src, 'io');
      expect(buildDotPath(module, src, 'File'), 'dart.io.File');
    });

    test('dart:core URI', () {
      final (module, src) = parseLibraryUri(Uri.parse('dart:core'));
      expect(module, 'dart');
      expect(src, 'core');
    });

    test('blank source path collapses', () {
      expect(buildDotPath('foo', '', 'Bar'), 'foo.Bar');
    });
  });

  group('Imports', () {
    test('extracts imports verbatim (as/show/hide stripped)', () {
      final r = DartExtractor.extractSyntactic('''
import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'dart:math' show sqrt;
import 'dart:convert' hide json;
''');
      expect(r.imports, [
        'dart:io',
        'dart:async',
        'package:path/path.dart',
        'dart:math',
        'dart:convert',
      ]);
    });
  });

  group('Declarations', () {
    test('class + members with kinds', () {
      final r = DartExtractor.extractSyntactic('''
class Foo {
  final String name;
  int count = 0;
  Foo(this.name);
  Foo.named(int v) : name = '\$v';
  String get displayName => name;
  set label(String v) {}
  void run(int x, {bool strict = false}) {}
  Foo operator +(Foo o) => this;
  static String create() => '';
}
''');
      expect(_kind(r, 'Foo'), 'class');
      expect(_sym(r, 'Foo', kind: 'constructor').parent, 'Foo');
      expect(_kind(r, 'Foo.named'), 'constructor');
      expect(_kind(r, 'name'), 'variable');
      expect(_kind(r, 'count'), 'variable');
      expect(_kind(r, 'displayName'), 'getter');
      expect(_kind(r, 'label'), 'setter');
      expect(_kind(r, 'run'), 'method');
      expect(_sym(r, 'run').signature, 'int x, {bool strict = false}');
      expect(_kind(r, 'operator +'), 'method');
      expect(_kind(r, 'create'), 'method');
      expect(_sym(r, 'displayName').parent, 'Foo');
    });

    test('enum / mixin / mixin class / extension / extension type', () {
      final r = DartExtractor.extractSyntactic('''
enum Color { red, green }
mixin MyMixin {}
mixin class MyMixinClass {}
extension StringExt on String {}
extension type Wrapper(int value) {}
''');
      expect(_kind(r, 'Color'), 'enum');
      expect(_kind(r, 'MyMixin'), 'mixin');
      expect(_kind(r, 'MyMixinClass'), 'class');
      expect(_kind(r, 'StringExt'), 'extension');
      expect(_kind(r, 'Wrapper'), 'extension');
    });

    test('typedefs (new + old style)', () {
      final r = DartExtractor.extractSyntactic('''
typedef Callback = void Function(int);
typedef void OldCallback(int value);
''');
      expect(_kind(r, 'Callback'), 'typedef');
      expect(_kind(r, 'OldCallback'), 'typedef');
    });

    test('top-level function, variable, constant', () {
      final r = DartExtractor.extractSyntactic('''
String helper() => 'hi';
const String version = '1.0';
final config = Object();
''');
      expect(_kind(r, 'helper'), 'function');
      expect(_sym(r, 'helper').signature, '');
      expect(_kind(r, 'version'), 'constant');
      expect(_kind(r, 'config'), 'variable');
    });

    test('does NOT treat control flow as declarations', () {
      final r = DartExtractor.extractSyntactic('''
void main() {
  if (true) {}
  for (var i = 0; i < 1; i++) {}
  while (true) {}
}
''');
      final fns = r.symbols
          .where((s) => s.kind == 'function')
          .map((s) => s.name);
      expect(fns, contains('main'));
      expect(fns, isNot(contains('if')));
      expect(fns, isNot(contains('for')));
    });
  });

  group('Visibility (private now included)', () {
    test('_-prefixed symbols are private, not dropped', () {
      final r = DartExtractor.extractSyntactic('''
class _Hidden {}
class Public {
  void _internal() {}
  void shown() {}
}
void _helper() {}
''');
      expect(_sym(r, '_Hidden').visibility, 'private');
      expect(_sym(r, 'Public').visibility, 'public');
      expect(_sym(r, '_internal').visibility, 'private');
      expect(_sym(r, 'shown').visibility, 'public');
      expect(_sym(r, '_helper').visibility, 'private');
    });

    test('private named constructor keyed on trailing identifier', () {
      final r = DartExtractor.extractSyntactic('''
class Foo {
  Foo._();
}
''');
      expect(_sym(r, 'Foo._').visibility, 'private');
    });
  });

  group('Line ranges (1-indexed, inclusive)', () {
    test('class and member spans', () {
      final r = DartExtractor.extractSyntactic(
        'class Foo {\n  void bar() {\n    return;\n  }\n}\n',
      );
      final foo = _sym(r, 'Foo');
      expect(foo.line, 1);
      expect(foo.endLine, 5);
      final bar = _sym(r, 'bar');
      expect(bar.line, 2);
      expect(bar.endLine, 4);
    });

    test('top-level function span after leading lines', () {
      final r = DartExtractor.extractSyntactic(
        '// a\n// b\nString greet() =>\n    "hi";\n',
      );
      final greet = _sym(r, 'greet');
      expect(greet.line, 3);
      expect(greet.endLine, 4);
    });
  });

  group('Annotations', () {
    test('TODO / FIXME / HACK / NOTE with author + line', () {
      final r = DartExtractor.extractSyntactic(
        '// line 1\n// TODO(john): fix this\n// FIXME: leak\n// HACK: x\n// NOTE: y',
      );
      final todo = r.annotations.firstWhere((a) => a['kind'] == 'TODO');
      expect(todo['message'], 'fix this');
      expect(todo['line'], 2);
      expect(r.annotations.firstWhere((a) => a['kind'] == 'FIXME')['line'], 3);
      expect(r.annotations.any((a) => a['kind'] == 'HACK'), isTrue);
      expect(r.annotations.any((a) => a['kind'] == 'NOTE'), isTrue);
    });

    test('DEPRECATED annotation', () {
      final r = DartExtractor.extractSyntactic('@deprecated\nclass Old {}');
      expect(
        r.annotations.where((a) => a['kind'] == 'DEPRECATED'),
        hasLength(1),
      );
    });
  });

  group('Edge cases', () {
    test('empty file', () {
      final r = DartExtractor.extractSyntactic('');
      expect(r.symbols, isEmpty);
      expect(r.imports, isEmpty);
      expect(r.references, isEmpty);
      expect(r.annotations, isEmpty);
    });

    test('braces inside strings and block comments', () {
      final r = DartExtractor.extractSyntactic('''
const greeting = '{ hello }';
/* { not a brace } */
class Foo {
  void bar() {}
}
''');
      expect(_kind(r, 'Foo'), 'class');
      expect(_sym(r, 'bar').parent, 'Foo');
    });
  });

  group('Resolved references (warm context)', () {
    late Directory tempDir;

    Future<void> pubGet() async {
      final r = await Process.run('dart', [
        'pub',
        'get',
      ], workingDirectory: tempDir.path);
      expect(r.exitCode, 0, reason: 'pub get failed: ${r.stderr}');
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dart_extractor_');
      await File('${tempDir.path}/pubspec.yaml').writeAsString('''
name: test_app
environment:
  sdk: ^3.9.3
''');
      await Directory('${tempDir.path}/lib').create();
    });

    tearDown(() async => tempDir.delete(recursive: true));

    test('dart:io File resolves to dart.io.File with count', () async {
      await File('${tempDir.path}/lib/main.dart').writeAsString('''
import 'dart:io';
void main() {
  File('a'); File('b'); File('c');
}
''');
      await pubGet();
      final ex = DartExtractor(projectPath: tempDir.path);
      final r = await ex.extractFile('${tempDir.path}/lib/main.dart');
      final file = r.references.firstWhere((u) => u.symbol == 'File');
      expect(file.dotPath, 'dart.io.File');
      expect(file.resolution, 'resolved');
      expect(file.count, greaterThanOrEqualTo(3));
      // Declarations came from the same resolved unit.
      expect(_kind(r, 'main'), 'function');
    });

    test('prefixed import resolves to defining library', () async {
      await File('${tempDir.path}/lib/main.dart').writeAsString('''
import 'dart:io' as io;
void main() { io.File('x'); }
''');
      await pubGet();
      final ex = DartExtractor(projectPath: tempDir.path);
      final r = await ex.extractFile('${tempDir.path}/lib/main.dart');
      expect(r.references.any((u) => u.dotPath == 'dart.io.File'), isTrue);
    });

    test('re-export resolves to the declaring library', () async {
      await File('${tempDir.path}/lib/base.dart').writeAsString('''
class Base {}
''');
      await File('${tempDir.path}/lib/api.dart').writeAsString('''
export 'base.dart';
''');
      await File('${tempDir.path}/lib/main.dart').writeAsString('''
import 'package:test_app/api.dart';
Base? thing;
''');
      await pubGet();
      final ex = DartExtractor(projectPath: tempDir.path);
      final r = await ex.extractFile('${tempDir.path}/lib/main.dart');
      final base = r.references.firstWhere((u) => u.symbol == 'Base');
      expect(base.dotPath, 'test_app.base.Base');
    });

    test('intra-project usage resolves to package dot-path', () async {
      await File('${tempDir.path}/lib/helper.dart').writeAsString('''
class Helper { static String greet() => 'hi'; }
''');
      await File('${tempDir.path}/lib/main.dart').writeAsString('''
import 'package:test_app/helper.dart';
void main() { Helper.greet(); }
''');
      await pubGet();
      final ex = DartExtractor(projectPath: tempDir.path);
      final r = await ex.extractFile('${tempDir.path}/lib/main.dart');
      final helper = r.references.firstWhere((u) => u.symbol == 'Helper');
      expect(helper.dotPath, 'test_app.helper.Helper');
    });

    test('warm context is reused and updated incrementally', () async {
      final path = '${tempDir.path}/lib/a.dart';
      await File(path).writeAsString('class One {}\n');
      await pubGet();

      final ex = DartExtractor(projectPath: tempDir.path);
      final first = await ex.extractFile(path);
      expect(first.symbols.map((s) => s.name), contains('One'));
      expect(first.symbols.map((s) => s.name), isNot(contains('Two')));

      // Mutate the file and notify the SAME extractor instance.
      await File(path).writeAsString('class One {}\nclass Two {}\n');
      await ex.notifyChanged(path);
      final second = await ex.extractFile(path);
      expect(second.symbols.map((s) => s.name), contains('Two'));
      expect(_sym(second, 'Two').line, 2);
    });
  });
}

// ── Helpers ─────────────────────────────────────────────────────────────

ExtractedSymbol _sym(ExtractedFile r, String name, {String? kind}) =>
    r.symbols.firstWhere(
      (s) => s.name == name && (kind == null || s.kind == kind),
      orElse: () => throw StateError(
        'Symbol "$name"${kind == null ? '' : ' ($kind)'} not found. '
        'Have: ${r.symbols.map((s) => "${s.name}:${s.kind}").join(", ")}',
      ),
    );

String _kind(ExtractedFile r, String name) => _sym(r, name).kind;
