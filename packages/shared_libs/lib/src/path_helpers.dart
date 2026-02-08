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

/// Check if a path is within any of the allowed paths.
/// Returns true if the path is exactly one of the allowed paths,
/// or is a child/descendant of any allowed path.
bool isAllowedPath(List<String> allowedPaths, String path) {
  final normalizedPath = normalize(path);
  
  return allowedPaths.any((String allowedRoot) {
    final normalizedRoot = normalize(allowedRoot);
    
    // Exact match
    if (normalizedPath == normalizedRoot) {
      return true;
    }
    
    // Check if path is a child of the allowed root
    // Ensure we match complete path segments (not partial names)
    // e.g., /lib should match /lib/models but NOT /library
    final rootWithSep = normalizedRoot.endsWith(separator)
        ? normalizedRoot
        : normalizedRoot + separator;
    
    return normalizedPath.startsWith(rootWithSep);
  });
}

/// Validate a relative path for safety
/// Returns null if valid, error message if invalid
String? validateRelativePath(String path) {
  if (path.startsWith('/')) {
    return 'No absolute paths allowed';
  }

  if (path.split('/').any((s) => s.startsWith('.') && s != '.')) {
    return 'No hidden files or directories allowed';
  }

  if (path.contains('..')) {
    return 'No parent directory traversal allowed';
  }

  return null;
}
