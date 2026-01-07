import 'dart:io';
import 'package:path/path.dart';

/// Get absolute path from a relative path based on working directory
String getAbsolutePath(Directory workingDir, String path) {
  final projectRootPath = workingDir.absolute.path;
  final outp = path == '.' ? projectRootPath : '$projectRootPath/$path';
  return normalize(outp);
}

/// Check if a path is hidden (starts with '.')
bool isHiddenPath(String path) {
  return path.split('/').any((segment) => segment.startsWith('.'));
}

/// Check if a path is within the allowed paths
bool isAllowedPath(List<String> allowedPaths, String path) {
  final normalizedPath = normalize(path);
  return allowedPaths.any((String root) {
    final normalizedRoot = normalize(root);
    return normalizedPath.startsWith(normalizedRoot) ||
        normalizedPath == normalizedRoot;
  });
}

/// Validate a relative path for safety
/// Returns null if valid, error message if invalid
String? validateRelativePath(String path) {
  if (path.startsWith('/')) {
    return 'No absolute paths allowed';
  }

  if (path.split('/').any((s) => s.startsWith('.'))) {
    return 'No hidden files or directories allowed';
  }

  if (path.contains('..')) {
    return 'No parent directory traversal allowed';
  }

  return null;
}
