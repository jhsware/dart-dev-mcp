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

/// Format allowed paths as relative paths for display in error messages.
///
/// Strips the [workingDir] prefix from each absolute allowed path to produce
/// user-friendly relative paths. Returns the formatted hint string.
String formatAllowedPathsHint(Directory workingDir, List<String> allowedPaths) {
  final relativePaths = getAllowedRelativePaths(workingDir, allowedPaths);
  return 'Allowed paths: ${relativePaths.join(', ')}';
}

/// Compute relative allowed paths from absolute allowed paths and working directory.
///
/// Returns a list of relative path strings suitable for display in error messages.
List<String> getAllowedRelativePaths(Directory workingDir, List<String> allowedPaths) {
  final prefix = '${workingDir.path}/';
  return allowedPaths.map((p) {
    return p.startsWith(prefix) ? p.substring(prefix.length) : p;
  }).toList();
}



/// Resolve an optional [workingDir] relative to [projectDir].
///
/// Returns [projectDir] itself when [workingDir] is null or empty.
/// Rejects absolute paths, `..`, hidden segments (via [validateRelativePath]),
/// paths that escape [projectDir] after normalization, non-existent paths,
/// and paths that are not directories.
///
/// Returns a record with either a resolved [Directory] or an error message.
({Directory? directory, String? error}) resolveWorkingDir(
    Directory projectDir, String? workingDir) {
  if (workingDir == null || workingDir.trim().isEmpty) {
    return (directory: projectDir, error: null);
  }

  final trimmed = workingDir.trim();

  // Reuse existing relative-path validation (absolute, hidden, ..)
  final validationError = validateRelativePath(trimmed);
  if (validationError != null) {
    return (directory: null, error: 'working_dir: $validationError');
  }

  final projectAbs = normalize(projectDir.absolute.path);
  final resolvedAbs = normalize('$projectAbs/$trimmed');

  // Defence-in-depth: ensure resolved path is inside project dir
  if (resolvedAbs != projectAbs &&
      !resolvedAbs.startsWith('$projectAbs$separator')) {
    return (
      directory: null,
      error: 'working_dir must resolve inside project_dir',
    );
  }

  // Check the resolved path exists and is a directory
  final stat = FileStat.statSync(resolvedAbs);
  if (stat.type == FileSystemEntityType.notFound) {
    return (directory: null, error: 'working_dir does not exist: $trimmed');
  }
  if (stat.type != FileSystemEntityType.directory) {
    return (
      directory: null,
      error: 'working_dir is not a directory: $trimmed',
    );
  }

  return (directory: Directory(resolvedAbs), error: null);
}
