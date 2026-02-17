import 'package:code_index_mcp/code_index_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('Import extraction', () {
    test('extracts single-quoted imports', () {
      final result = DartParser.parse("import 'dart:io';");
      expect(result.imports, ['dart:io']);
    });

    test('extracts double-quoted imports', () {
      final result = DartParser.parse('import "dart:io";');
      expect(result.imports, ['dart:io']);
    });

    test('extracts package imports', () {
      final result = DartParser.parse("import 'package:path/path.dart';");
      expect(result.imports, ['package:path/path.dart']);
    });

    test('extracts imports with as', () {
      final result =
          DartParser.parse("import 'package:path/path.dart' as p;");
      expect(result.imports, ['package:path/path.dart']);
    });

    test('extracts imports with show', () {
      final result = DartParser.parse("import 'dart:math' show sqrt;");
      expect(result.imports, ['dart:math']);
    });

    test('extracts imports with hide', () {
      final result = DartParser.parse("import 'dart:io' hide File;");
      expect(result.imports, ['dart:io']);
    });

    test('handles multiple imports', () {
      final result = DartParser.parse('''
import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as p;
''');
      expect(result.imports,
          ['dart:io', 'dart:async', 'package:path/path.dart']);
    });
  });

  group('Class declarations', () {
    test('extracts simple class', () {
      final result = DartParser.parse('class Foo {}');
      _expectExport(result.exports, 'Foo', 'class');
    });

    test('extracts abstract class', () {
      final result = DartParser.parse('abstract class Foo {}');
      _expectExport(result.exports, 'Foo', 'class');
    });

    test('extracts sealed class', () {
      final result = DartParser.parse('sealed class Foo {}');
      _expectExport(result.exports, 'Foo', 'class');
    });

    test('extracts base class', () {
      final result = DartParser.parse('base class Foo {}');
      _expectExport(result.exports, 'Foo', 'class');
    });

    test('extracts final class', () {
      final result = DartParser.parse('final class Foo {}');
      _expectExport(result.exports, 'Foo', 'class');
    });

    test('extracts interface class', () {
      final result = DartParser.parse('interface class Foo {}');
      _expectExport(result.exports, 'Foo', 'class');
    });

    test('extracts class with generics', () {
      final result = DartParser.parse('class Foo<T extends Bar> {}');
      _expectExport(result.exports, 'Foo', 'class');
    });

    test('extracts class with extends/implements/with', () {
      final result = DartParser.parse(
          'class Foo extends Bar with Mixin implements Interface {}');
      _expectExport(result.exports, 'Foo', 'class');
    });

    test('skips private classes', () {
      final result = DartParser.parse('class _PrivateFoo {}');
      expect(result.exports, isEmpty);
    });
  });

  group('Enum declarations', () {
    test('extracts simple enum', () {
      final result = DartParser.parse('enum Color { red, green, blue }');
      _expectExport(result.exports, 'Color', 'enum');
    });

    test('extracts enhanced enum with methods', () {
      final result = DartParser.parse('''
enum Status {
  active,
  inactive;
  
  String get label => name;
}
''');
      _expectExport(result.exports, 'Status', 'enum');
    });
  });

  group('Mixin declarations', () {
    test('extracts mixin', () {
      final result = DartParser.parse('mixin MyMixin {}');
      _expectExport(result.exports, 'MyMixin', 'mixin');
    });

    test('extracts mixin class', () {
      final result = DartParser.parse('mixin class MyMixinClass {}');
      _expectExport(result.exports, 'MyMixinClass', 'mixin');
    });

    test('extracts base mixin', () {
      final result = DartParser.parse('base mixin MyBaseMixin {}');
      _expectExport(result.exports, 'MyBaseMixin', 'mixin');
    });
  });

  group('Extension declarations', () {
    test('extracts extension', () {
      final result =
          DartParser.parse('extension StringExt on String {}');
      _expectExport(result.exports, 'StringExt', 'extension');
    });

    test('extracts extension type', () {
      final result =
          DartParser.parse('extension type Wrapper(int value) {}');
      _expectExport(result.exports, 'Wrapper', 'extension');
    });
  });

  group('Typedef declarations', () {
    test('extracts typedef', () {
      final result =
          DartParser.parse('typedef Callback = void Function(int);');
      _expectExport(result.exports, 'Callback', 'typedef');
    });

    test('extracts old-style typedef', () {
      final result =
          DartParser.parse('typedef void OldCallback(int value);');
      _expectExport(result.exports, 'OldCallback', 'typedef');
    });
  });

  group('Top-level functions', () {
    test('extracts function with return type', () {
      final result =
          DartParser.parse('String helper() => "hello";');
      _expectExport(result.exports, 'helper', 'function');
    });

    test('extracts void function', () {
      final result =
          DartParser.parse('void main(List<String> args) {}');
      _expectExport(result.exports, 'main', 'function');
    });

    test('extracts async function', () {
      final result =
          DartParser.parse('Future<String> fetchData() async {}');
      _expectExport(result.exports, 'fetchData', 'function');
    });

    test('extracts function parameters', () {
      final result =
          DartParser.parse('void doStuff(String name, int count) {}');
      final fn = _findExport(result.exports, 'doStuff');
      expect(fn['parameters'], 'String name, int count');
    });

    test('skips private functions', () {
      final result = DartParser.parse('void _helper() {}');
      expect(result.exports, isEmpty);
    });

    test('does NOT extract control flow as functions', () {
      final result = DartParser.parse('''
void main() {
  if (true) {}
  for (var i = 0; i < 10; i++) {}
  while (true) {}
  switch (x) {}
}
''');
      final fns = result.exports
          .where((e) => e['kind'] == 'function')
          .map((e) => e['name']);
      expect(fns, contains('main'));
      expect(fns, isNot(contains('if')));
      expect(fns, isNot(contains('for')));
      expect(fns, isNot(contains('while')));
      expect(fns, isNot(contains('switch')));
    });
  });

  group('Methods inside classes', () {
    test('extracts public methods with parent_name', () {
      final result = DartParser.parse('''
class Foo {
  void doSomething() {}
}
''');
      final method = _findExport(result.exports, 'doSomething');
      expect(method['kind'], 'method');
      expect(method['parent_name'], 'Foo');
    });

    test('extracts static methods', () {
      final result = DartParser.parse('''
class Foo {
  static String create() => '';
}
''');
      final method = _findExport(result.exports, 'create');
      expect(method['kind'], 'method');
      expect(method['parent_name'], 'Foo');
    });

    test('extracts constructors', () {
      final result = DartParser.parse('''
class Foo {
  Foo(String name) {}
}
''');
      final ctors = result.exports
          .where((e) => e['name'] == 'Foo' && e['kind'] == 'method');
      expect(ctors, hasLength(1));
      expect(ctors.first['parent_name'], 'Foo');
    });

    test('extracts named constructors', () {
      final result = DartParser.parse('''
class Foo {
  Foo.named(int value) {}
}
''');
      final ctor = _findExport(result.exports, 'Foo.named');
      expect(ctor['kind'], 'method');
      expect(ctor['parent_name'], 'Foo');
    });

    test('extracts factory constructors', () {
      final result = DartParser.parse('''
class Foo {
  factory Foo.create() => Foo._();
  Foo._();
}
''');
      final factory = _findExport(result.exports, 'Foo.create');
      expect(factory['kind'], 'method');
      expect(factory['parent_name'], 'Foo');
    });

    test('skips private methods', () {
      final result = DartParser.parse('''
class Foo {
  void _internal() {}
  void publicMethod() {}
}
''');
      final names = result.exports.map((e) => e['name']).toList();
      expect(names, isNot(contains('_internal')));
      expect(names, contains('publicMethod'));
    });

    test('includes parameter signatures', () {
      final result = DartParser.parse('''
class Foo {
  String convert(int value, {bool strict = false}) {}
}
''');
      final method = _findExport(result.exports, 'convert');
      expect(method['parameters'], contains('int value'));
      expect(method['parameters'], contains('bool strict'));
    });
  });

  group('Class members', () {
    test('extracts public getters', () {
      final result = DartParser.parse('''
class Foo {
  String get name => _name;
}
''');
      final getter = _findExport(result.exports, 'name');
      expect(getter['kind'], 'class_member');
      expect(getter['parent_name'], 'Foo');
    });

    test('extracts public setters', () {
      final result = DartParser.parse('''
class Foo {
  set name(String value) {}
}
''');
      final setter = _findExport(result.exports, 'name');
      expect(setter['kind'], 'class_member');
      expect(setter['parent_name'], 'Foo');
    });

    test('extracts public fields', () {
      final result = DartParser.parse('''
class Foo {
  final String name;
  int count = 0;
}
''');
      final names = result.exports
          .where((e) => e['kind'] == 'class_member')
          .map((e) => e['name'])
          .toList();
      expect(names, contains('name'));
      expect(names, contains('count'));
    });

    test('skips private fields', () {
      final result = DartParser.parse('''
class Foo {
  final String _name;
  final String title;
}
''');
      final names = result.exports
          .where((e) => e['kind'] == 'class_member')
          .map((e) => e['name'])
          .toList();
      expect(names, isNot(contains('_name')));
      expect(names, contains('title'));
    });
  });

  group('Top-level variables', () {
    test('extracts const', () {
      final result = DartParser.parse("const String version = '1.0';");
      _expectVariable(result.variables, 'version');
    });

    test('extracts final', () {
      final result = DartParser.parse('final config = Config();');
      _expectVariable(result.variables, 'config');
    });

    test('extracts late final', () {
      final result = DartParser.parse('late final Database db;');
      _expectVariable(result.variables, 'db');
    });

    test('skips private variables', () {
      final result = DartParser.parse('const _internal = true;');
      expect(result.variables, isEmpty);
    });
  });

  group('Annotations', () {
    test('extracts TODO comments', () {
      final result = DartParser.parse('// TODO: fix this');
      expect(result.annotations, hasLength(1));
      expect(result.annotations.first['kind'], 'TODO');
      expect(result.annotations.first['message'], 'fix this');
    });

    test('extracts TODO with author', () {
      final result = DartParser.parse('// TODO(john): fix this');
      expect(result.annotations.first['kind'], 'TODO');
      expect(result.annotations.first['message'], 'fix this');
    });

    test('extracts FIXME comments', () {
      final result = DartParser.parse('// FIXME: memory leak');
      expect(result.annotations.first['kind'], 'FIXME');
      expect(result.annotations.first['message'], 'memory leak');
    });

    test('extracts HACK comments', () {
      final result = DartParser.parse('// HACK: workaround');
      expect(result.annotations.first['kind'], 'HACK');
      expect(result.annotations.first['message'], 'workaround');
    });

    test('extracts NOTE comments', () {
      final result = DartParser.parse('// NOTE: important detail');
      expect(result.annotations.first['kind'], 'NOTE');
      expect(result.annotations.first['message'], 'important detail');
    });

    test('extracts @deprecated annotations', () {
      final result = DartParser.parse('@deprecated\nclass OldClass {}');
      final deprecated = result.annotations
          .where((a) => a['kind'] == 'DEPRECATED');
      expect(deprecated, hasLength(1));
    });

    test('reports correct line numbers', () {
      final source = '// line 1\n// line 2\n// TODO: on line 3\n// line 4\n// FIXME: on line 5';
      final result = DartParser.parse(source);
      final todo = result.annotations
          .firstWhere((a) => a['kind'] == 'TODO');
      expect(todo['line'], 3);
      final fixme = result.annotations
          .firstWhere((a) => a['kind'] == 'FIXME');
      expect(fixme['line'], 5);
    });
  });

  group('Edge cases', () {
    test('handles empty files', () {
      final result = DartParser.parse('');
      expect(result.imports, isEmpty);
      expect(result.exports, isEmpty);
      expect(result.variables, isEmpty);
      expect(result.annotations, isEmpty);
    });

    test('handles files with only imports', () {
      final result = DartParser.parse('''
import 'dart:io';
import 'dart:async';
''');
      expect(result.imports, hasLength(2));
      expect(result.exports, isEmpty);
      expect(result.variables, isEmpty);
    });

    test('handles string literals containing braces', () {
      final result = DartParser.parse('''
const greeting = '{ hello }';
class Foo {
  void bar() {}
}
''');
      _expectExport(result.exports, 'Foo', 'class');
      final bar = _findExport(result.exports, 'bar');
      expect(bar['kind'], 'method');
      expect(bar['parent_name'], 'Foo');
    });

    test('handles block comments with braces', () {
      final result = DartParser.parse('''
/* { not a real brace } */
class Foo {
  void bar() {}
}
''');
      _expectExport(result.exports, 'Foo', 'class');
      final bar = _findExport(result.exports, 'bar');
      expect(bar['kind'], 'method');
      expect(bar['parent_name'], 'Foo');
    });

    test('handles operator overloads', () {
      final result = DartParser.parse('''
class Vector {
  Vector operator +(Vector other) => Vector();
}
''');
      final op = _findExport(result.exports, 'operator +');
      expect(op['kind'], 'method');
      expect(op['parent_name'], 'Vector');
    });
  });

  group('Full file parsing', () {
    test('parses a realistic Dart file', () {
      final result = DartParser.parse('''
import 'dart:io';
import 'package:path/path.dart' as p;

// TODO: Add logging support

const String version = '1.0.0';

typedef Callback = void Function(String);

/// Main application class
class App {
  final String name;
  
  App(this.name);
  App.withDefault() : name = 'default';
  
  String get displayName => name.toUpperCase();
  
  void run(List<String> args) {
    // FIXME: handle errors
    print('Running \$name');
  }
  
  void _internal() {}
}

abstract class Base {
  void process();
}

mixin Logging {
  void log(String message) {}
}

enum Status { active, inactive }

void main(List<String> args) {}

String _privateHelper() => '';
''');
      // Imports
      expect(result.imports, hasLength(2));
      expect(result.imports, contains('dart:io'));
      expect(result.imports, contains('package:path/path.dart'));

      // Top-level declarations
      _expectExport(result.exports, 'App', 'class');
      _expectExport(result.exports, 'Base', 'class');
      _expectExport(result.exports, 'Logging', 'mixin');
      _expectExport(result.exports, 'Status', 'enum');
      _expectExport(result.exports, 'Callback', 'typedef');

      // Top-level function
      final mainFn = _findExport(result.exports, 'main');
      expect(mainFn['kind'], 'function');

      // Class members of App
      final appExports = result.exports
          .where((e) => e['parent_name'] == 'App')
          .map((e) => e['name'])
          .toList();
      expect(appExports, contains('name')); // field
      expect(appExports, contains('App')); // constructor
      expect(appExports, contains('App.withDefault')); // named ctor
      expect(appExports, contains('displayName')); // getter
      expect(appExports, contains('run')); // method

      // Private members excluded
      final allNames = result.exports.map((e) => e['name']).toList();
      expect(allNames, isNot(contains('_internal')));
      expect(allNames, isNot(contains('_privateHelper')));

      // Variables
      _expectVariable(result.variables, 'version');

      // Annotations
      expect(result.annotations, hasLength(2)); // TODO + FIXME
      final todo = result.annotations
          .firstWhere((a) => a['kind'] == 'TODO');
      expect(todo['message'], 'Add logging support');
      final fixme = result.annotations
          .firstWhere((a) => a['kind'] == 'FIXME');
      expect(fixme['message'], 'handle errors');
    });
  });
}

/// Assert that an export with [name] and [kind] exists in the list.
void _expectExport(List<Map<String, String?>> exports, String name, String kind) {
  final matches = exports.where((e) => e['name'] == name && e['kind'] == kind);
  expect(matches, hasLength(1),
      reason: 'Expected export "$name" with kind "$kind" but found: '
          '${exports.map((e) => "${e['name']}(${e['kind']})").join(", ")}');
}

/// Find an export by name.
Map<String, String?> _findExport(List<Map<String, String?>> exports, String name) {
  return exports.firstWhere(
    (e) => e['name'] == name,
    orElse: () => throw StateError(
        'Export "$name" not found. Available: '
        '${exports.map((e) => e['name']).join(", ")}'),
  );
}

/// Assert that a variable with [name] exists in the list.
void _expectVariable(List<Map<String, String?>> variables, String name) {
  final matches = variables.where((v) => v['name'] == name);
  expect(matches, hasLength(1),
      reason: 'Expected variable "$name" but found: '
          '${variables.map((v) => v['name']).join(", ")}');
}
