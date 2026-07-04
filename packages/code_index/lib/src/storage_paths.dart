import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Pure path-derivation helpers for the standalone `~/.code-index` store
/// (design §3.1). No database access; the only IO performed is directory
/// creation ([ensureDataDir]) and symlink resolution ([canonicalProjectPath]).

/// File name for a project's SQLite database inside its data directory.
const String codeIndexDbFileName = 'code_index.db';

/// Replace any character outside `[A-Za-z0-9._-]` with `_` so the basename is
/// safe to use as a directory name on every platform.
String sanitizeBasename(String basename) {
  return basename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

/// The canonical form of a project path: absolute, normalized, and with
/// symlinks resolved. Falls back to the normalized absolute path when the
/// directory does not exist on disk (so derivation stays deterministic in
/// tests and for not-yet-created projects).
String canonicalProjectPath(String projectDir) {
  final absolute = p.normalize(p.absolute(projectDir));
  final dir = Directory(absolute);
  if (dir.existsSync()) {
    return dir.resolveSymbolicLinksSync();
  }
  return absolute;
}

/// First 8 hex characters of the SHA-256 of [input].
String sha8(String input) {
  final digest = sha256.convert(utf8.encode(input));
  return digest.toString().substring(0, 8);
}

/// The directory name for a project: `<sanitizedBasename>-<sha8>` where the
/// hash is taken over the canonical (symlink-resolved) project path.
String dataDirNameFor(String projectDir) {
  final canonical = canonicalProjectPath(projectDir);
  final base = sanitizeBasename(p.basename(canonical));
  return '$base-${sha8(canonical)}';
}

/// Absolute data directory for a project: `<dataRoot>/<dataDirNameFor>`.
String dataDirFor(String dataRoot, String projectDir) {
  return p.join(dataRoot, dataDirNameFor(projectDir));
}

/// Absolute path to a project's SQLite database.
String dbPathFor(String dataRoot, String projectDir) {
  return p.join(dataDirFor(dataRoot, projectDir), codeIndexDbFileName);
}

/// Create the project's data directory (recursively) and return it.
Directory ensureDataDir(String dataRoot, String projectDir) {
  final dir = Directory(dataDirFor(dataRoot, projectDir));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return dir;
}
