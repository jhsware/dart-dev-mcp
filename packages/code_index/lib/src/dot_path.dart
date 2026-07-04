/// Dot-path canonicalization for external symbol references.
///
/// Turns a library URI into a `(module, sourcePath)` pair and joins it with a
/// symbol name into a canonical `<module>.<source_path>.<symbol>` dot-path
/// (design §8.4). These functions are pure and dependency-free so the write
/// path can reuse them to normalize agent-declared references.
library;

/// Parse a library [uri] into its `(module, sourcePath)` components.
///
/// Rules (design §8.4):
/// - `package:foo/bar/baz.dart` → `('foo', 'bar.baz')`
/// - `package:foo/foo.dart`     → `('foo', 'foo')`
/// - `dart:io`                  → `('dart', 'io')`
/// - `file:///a/b/c.dart` or other → `('unknown', 'a.b.c')`
///
/// The `.dart` suffix is stripped and path separators become dots.
(String module, String sourcePath) parseLibraryUri(Uri uri) {
  switch (uri.scheme) {
    case 'package':
      final path = uri.path; // e.g. foo/bar/baz.dart
      final slash = path.indexOf('/');
      if (slash < 0) return (pathToDotted(path), '');
      final module = path.substring(0, slash);
      final rest = path.substring(slash + 1);
      return (module, pathToDotted(rest));
    case 'dart':
      // dart:io — the library name lives in the path (or host for dart:core).
      final name = uri.path.isNotEmpty ? uri.path : uri.host;
      return ('dart', name);
    default:
      return ('unknown', pathToDotted(uri.path));
  }
}

/// Convenience overload that parses a raw [uri] string.
(String module, String sourcePath) parseLibraryUriString(String uri) =>
    parseLibraryUri(Uri.parse(uri));

/// Build the canonical dot-path `<module>.<source_path>.<symbol>`.
///
/// A blank [sourcePath] collapses to `<module>.<symbol>`.
String buildDotPath(String module, String sourcePath, String symbol) =>
    sourcePath.isEmpty ? '$module.$symbol' : '$module.$sourcePath.$symbol';

/// Convert a slash-separated source path into a dotted one, dropping a
/// trailing `.dart` extension. `bar/baz.dart` → `bar.baz`.
String pathToDotted(String path) {
  var result = path;
  if (result.endsWith('.dart')) {
    result = result.substring(0, result.length - 5);
  }
  // Trim leading/trailing slashes so we never emit empty segments.
  result = result.replaceAll(RegExp(r'^/+|/+$'), '');
  return result.replaceAll('/', '.');
}
