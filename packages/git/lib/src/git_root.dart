import 'dart:io';

import 'package:path/path.dart' as p;

/// Walks up the directory tree from [startDir] looking for a `.git` entry.
///
/// Returns the absolute, normalized path of the first ancestor directory
/// (inclusive of [startDir]) that contains a `.git` entry — either a directory
/// (normal repos) or a file (git worktrees and submodules).
///
/// Returns `null` if no `.git` entry is found up to the filesystem root.
///
/// The walk uses the raw [startDir] string without resolving symlinks, so
/// callers that pass `--project-dir` values walk from the exact path the MCP
/// was launched with.
///
/// [stopAt] is an optional boundary for testing: when set, the walk stops
/// (returning `null`) once it would move above that directory.
String? findGitRoot(String startDir, {String? stopAt}) {
  var current = p.normalize(p.absolute(startDir));
  final boundary = stopAt != null ? p.normalize(p.absolute(stopAt)) : null;

  while (true) {
    final gitPath = p.join(current, '.git');
    final type = FileSystemEntity.typeSync(gitPath, followLinks: false);
    if (type == FileSystemEntityType.directory ||
        type == FileSystemEntityType.file) {
      return current;
    }

    final parent = p.dirname(current);
    if (parent == current) {
      // Reached filesystem root without finding .git
      return null;
    }
    if (boundary != null && current == boundary) {
      // Reached the test boundary without finding .git
      return null;
    }
    current = parent;
  }
}
