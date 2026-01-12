import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'package:dart_dev_mcp/dart_dev_mcp.dart';

/// File read operations handler.
///
/// Provides methods for listing, reading, and searching files.
class FileReadOperations {
  final Directory workingDir;
  final List<String> allowedPaths;

  FileReadOperations({
    required this.workingDir,
    required this.allowedPaths,
  });

  /// List content recursively.
  Future<CallToolResult> listContent(String path) async {
    final pathError = validateRelativePath(path);
    if (pathError != null && path != '.') {
      return validationError('path', pathError);
    }

    final dirPath = getAbsolutePath(workingDir, path);
    if (!isAllowedPath(allowedPaths, dirPath)) {
      return validationError('path', 'Not allowed for: $path');
    }

    final directory = Directory(dirPath);
    if (!await directory.exists()) {
      return notFoundError('Directory', path);
    }

    final List<FileSystemEntity> allContents = await directory.list().toList();
    final output = <String>[];

    while (allContents.isNotEmpty) {
      final List<FileSystemEntity> currentBatch = List.from(allContents);
      allContents.clear();

      final futures = currentBatch.map((item) async {
        final relPath = item.path.substring(workingDir.path.length + 1);

        // Omit hidden files
        if (isHiddenPath(relPath)) return '';

        final stat = await item.stat();
        if (stat.type == FileSystemEntityType.directory) {
          allContents.addAll(await Directory(item.path).list().toList());
        }
        return '$relPath -- size: ${stat.size}; type: ${stat.type}';
      });
      output.addAll(await Future.wait(futures));
    }

    final filtered = output.where((s) => s.isNotEmpty).toList();
    return textResult(
        filtered.isEmpty ? 'Directory is empty' : filtered.join('\n'));
  }

  /// Read a single file with line numbers.
  Future<CallToolResult> readFile(String path) async {
    final pathError = validateRelativePath(path);
    if (pathError != null) {
      return validationError('path', pathError);
    }

    final filePath = getAbsolutePath(workingDir, path);
    if (!isAllowedPath(allowedPaths, filePath)) {
      return validationError('path', 'Not allowed for: $path');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return notFoundError('File', path);
    }

    final content = await file.readAsString();
    final normalized = normalizeLineEndings(content);
    return textResult(addLineNumbers(normalized));
  }

  /// Read multiple files.
  Future<CallToolResult> readFiles(List<String> paths) async {
    final output = <String>[];

    for (final path in paths) {
      final trimmedPath = path.trim();
      final pathError = validateRelativePath(trimmedPath);
      if (pathError != null) {
        output.add('$trimmedPath: Error: $pathError');
        continue;
      }

      final filePath = getAbsolutePath(workingDir, trimmedPath);
      if (!isAllowedPath(allowedPaths, filePath)) {
        output.add('$trimmedPath: Error: Not allowed');
        continue;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        output.add('$trimmedPath: Error: File not found');
        continue;
      }

      final content = await file.readAsString();
      final normalized = normalizeLineEndings(content);
      output.addAll(['$trimmedPath:', addLineNumbers(normalized), '']);
    }

    return textResult(output.join('\n'));
  }

  /// Search for text pattern in files.
  Future<CallToolResult> searchText(
    String path,
    String? pattern,
    String? filePattern,
    bool caseSensitive,
  ) async {
    if (requireString(pattern, 'pattern') case final error?) {
      return error;
    }

    final pathError = validateRelativePath(path);
    if (pathError != null && path != '.') {
      return validationError('path', pathError);
    }

    final dirPath = getAbsolutePath(workingDir, path);
    if (!isAllowedPath(allowedPaths, dirPath)) {
      return validationError('path', 'Not allowed for: $path');
    }

    final directory = Directory(dirPath);
    if (!await directory.exists()) {
      return notFoundError('Directory', path);
    }

    // Validate regex
    RegExp regex;
    try {
      regex = RegExp(pattern!, caseSensitive: caseSensitive);
    } catch (e) {
      return validationError('pattern', 'Invalid regex pattern: $e');
    }

    // Try grep first, fall back to Dart
    try {
      return await _searchWithGrep(
        dirPath,
        pattern,
        filePattern,
        caseSensitive,
      );
    } catch (e) {
      return await _searchWithDart(
        dirPath,
        regex,
        filePattern,
      );
    }
  }

  Future<CallToolResult> _searchWithGrep(
    String dirPath,
    String pattern,
    String? filePattern,
    bool caseSensitive,
  ) async {
    final args = <String>[
      '-r',
      '-n',
      '-E',
      '--include=${filePattern ?? '*'}',
      if (!caseSensitive) '-i',
      pattern,
      dirPath,
    ];

    final result = await Process.run('grep', args);

    if (result.exitCode != 0 && result.exitCode != 1) {
      throw Exception('grep failed: ${result.stderr}');
    }

    final stdout = result.stdout as String;
    if (stdout.isEmpty) {
      return textResult('[]');
    }

    final matches = <Map<String, dynamic>>[];
    final lines = stdout.split('\n');

    for (final line in lines) {
      if (line.isEmpty) continue;

      final firstColonIdx = line.indexOf(':');
      if (firstColonIdx == -1) continue;

      final afterFirstColon = line.substring(firstColonIdx + 1);
      final secondColonIdx = afterFirstColon.indexOf(':');
      if (secondColonIdx == -1) continue;

      final filePath = line.substring(0, firstColonIdx);
      final lineNumStr = afterFirstColon.substring(0, secondColonIdx);
      final content = afterFirstColon.substring(secondColonIdx + 1);

      final lineNum = int.tryParse(lineNumStr);
      if (lineNum == null) continue;

      String relPath = filePath;
      if (filePath.startsWith(workingDir.path)) {
        relPath = filePath.substring(workingDir.path.length + 1);
      }

      if (isHiddenPath(relPath)) continue;

      matches.add({
        'file': relPath,
        'line': lineNum,
        'content': content.trim(),
      });
    }

    return textResult(jsonEncode(matches));
  }

  Future<CallToolResult> _searchWithDart(
    String dirPath,
    RegExp regex,
    String? filePattern,
  ) async {
    final fileRegex = filePattern != null ? globToRegex(filePattern) : null;
    final matches = <Map<String, dynamic>>[];
    final directory = Directory(dirPath);

    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final filePath = entity.path;
      final fileName = filePath.split('/').last;

      final relPath = filePath.startsWith(workingDir.path)
          ? filePath.substring(workingDir.path.length + 1)
          : filePath;

      if (isHiddenPath(relPath)) continue;

      if (fileRegex != null && !fileRegex.hasMatch(fileName)) continue;

      try {
        final content = await entity.readAsString();
        final lines = content.split('\n');

        for (var i = 0; i < lines.length; i++) {
          if (regex.hasMatch(lines[i])) {
            matches.add({
              'file': relPath,
              'line': i + 1,
              'content': lines[i].trim(),
            });
          }
        }
      } catch (e) {
        // Skip binary files
        continue;
      }
    }

    return textResult(jsonEncode(matches));
  }
}

/// Convert a glob pattern to a regular expression.
RegExp globToRegex(String glob) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    switch (c) {
      case '*':
        buffer.write('.*');
        break;
      case '?':
        buffer.write('.');
        break;
      case '.':
      case '(':
      case ')':
      case '[':
      case ']':
      case '{':
      case '}':
      case '^':
      case r'$':
      case '|':
      case r'\':
      case '+':
        buffer.write('\\$c');
        break;
      default:
        buffer.write(c);
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}
