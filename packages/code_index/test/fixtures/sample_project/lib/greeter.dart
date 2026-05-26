import 'dart:io';

import 'package:path/path.dart' as p;

/// A simple greeting service.
class Greeter {
  final String name;

  Greeter(this.name);

  /// Returns a greeting string.
  String greet() => 'Hello, $name!';

  /// Prints the current working directory basename.
  String cwd() => p.basename(Directory.current.path);
}

// TODO: Add localization support
const defaultLocale = 'en';

/// Top-level helper that creates and runs a greeter.
void runGreeter(String name) {
  final g = Greeter(name);
  stdout.writeln(g.greet());
}

enum Mood { happy, sad, neutral }
