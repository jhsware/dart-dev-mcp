import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'package:jhsware_code_shared_libs/shared_libs.dart';

/// File write operations handler.
///
/// Provides methods for creating and editing files and directories.
class FileWriteOperations {
  final Directory workingDir;
  final List<String> allowedPaths;

  FileWriteOperations({
    required this.workingDir,
    required this.allowedPaths,
  });

  /// Allowed paths formatted as relative paths for error messages.
  late final String _allowedPathsHint =
      formatAllowedPathsHint(workingDir, allowedPaths);

  /// Create a new directory.
  Future<CallToolResult> createDirectory(String path) async {
    final pathError = validateRelativePath(path);
    if (pathError != null) {
      return validationError('path', pathError);
    }

    final dirPath = getAbsolutePath(workingDir, path);
    if (!isAllowedPath(allowedPaths, dirPath)) {
      return validationError('path', 'Not allowed for: $path. $_allowedPathsHint');
    }

    final directory = Directory(dirPath);
    if (await directory.exists()) {
      return textResult('Directory already exists: $path');
    }

    await directory.create(recursive: true);
    return textResult('Created directory: $path');
  }

  /// Create a new file with optional content.
  Future<CallToolResult> createFile(String path, String? content) async {
    final pathError = validateRelativePath(path);
    if (pathError != null) {
      return validationError('path', pathError);
    }

    final filePath = getAbsolutePath(workingDir, path);
    if (!isAllowedPath(allowedPaths, filePath)) {
      return validationError('path', 'Not allowed for: $path. $_allowedPathsHint');
    }

    final file = File(filePath);
    if (await file.exists()) {
      return validationError('path', 'File already exists: $path');
    }

    await file.create(recursive: true);

    if (content != null) {
      final cleanContent = stripLineNumbers(content);
      await file.writeAsString(cleanContent);
    }

    return textResult('Created file: $path');
  }

  /// Edit file content (overwrite, insert, or replace lines).
  Future<CallToolResult> editFile(
    String path,
    String? content,
    int? startLine,
    int? endLine,
  ) async {
    final pathError = validateRelativePath(path);
    if (pathError != null) {
      return validationError('path', pathError);
    }

    final filePath = getAbsolutePath(workingDir, path);
    if (!isAllowedPath(allowedPaths, filePath)) {
      return validationError('path', 'Not allowed for: $path. $_allowedPathsHint');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return notFoundError('File', path);
    }

    if (requireString(content, 'content') case final error?) {
      return error;
    }

    // Validate line numbers
    if (startLine != null && startLine < 1) {
      return validationError('startLine', 'startLine must be >= 1');
    }
    if (endLine != null && endLine < 1) {
      return validationError('endLine', 'endLine must be >= 1');
    }
    if (endLine != null && startLine == null) {
      return validationError('endLine', 'endLine requires startLine');
    }
    if (startLine != null && endLine != null && endLine < startLine) {
      return validationError('endLine', 'endLine must be >= startLine');
    }

    // Read existing content and detect line endings
    final existingContent = await file.readAsString();
    final lineEndingStyle = existingContent.isNotEmpty
        ? detectLineEndings(existingContent)
        : detectLineEndings(content!);

    final normalizedExisting = normalizeLineEndings(existingContent);
    final existingLines = normalizedExisting.split('\n');

    final cleanContent = stripLineNumbers(content!);
    final normalizedNew = normalizeLineEndings(cleanContent);
    final newLines = normalizedNew.split('\n');

    String resultContent;
    String operationDesc;

    if (startLine == null) {
      // Mode 1: Overwrite entire file
      resultContent = normalizedNew;
      operationDesc = 'Overwrote entire file';
    } else if (endLine == null) {
      // Mode 2: Insert at line
      final insertIndex = startLine - 1;

      if (insertIndex > existingLines.length) {
        final padding = List.filled(insertIndex - existingLines.length, '');
        existingLines.addAll(padding);
      }

      existingLines.insertAll(insertIndex, newLines);
      resultContent = existingLines.join('\n');
      operationDesc = 'Inserted ${newLines.length} line(s) at line $startLine';
    } else {
      // Mode 3: Replace line range
      final startIndex = startLine - 1;
      final endIndex = endLine;

      if (startIndex >= existingLines.length) {
        return validationError(
          'startLine',
          'startLine ($startLine) exceeds file length (${existingLines.length} lines)',
        );
      }

      final actualEndIndex =
          endIndex > existingLines.length ? existingLines.length : endIndex;

      existingLines.removeRange(startIndex, actualEndIndex);
      existingLines.insertAll(startIndex, newLines);

      resultContent = existingLines.join('\n');
      final replacedCount = actualEndIndex - startIndex;
      operationDesc =
          'Replaced $replacedCount line(s) (lines $startLine-${startIndex + replacedCount}) with ${newLines.length} line(s)';
    }

    final finalContent = applyLineEndings(resultContent, lineEndingStyle);
    await file.writeAsString(finalContent);

    return textResult('Success: $operationDesc in $path');
  }
}
