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
      return validationError('path', '$pathError. $_allowedPathsHint');
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
      return validationError('path', '$pathError. $_allowedPathsHint');
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
      return validationError('path', '$pathError. $_allowedPathsHint');
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

  /// Extract lines from source file and insert into destination file.
  ///
  /// This performs the operation server-side without content passing through
  /// the LLM context, making it efficient for refactoring large files.
  Future<CallToolResult> extractLines(
    String sourcePath,
    String? destinationPath,
    int? startLine,
    int? endLine,
    int? insertAt,
    bool removeFromSource,
  ) async {
    // 1. Validate required parameters
    if (requireString(destinationPath, 'destination') case final error?) {
      return error;
    }
    if (startLine == null) {
      return validationError('startLine', 'startLine is required for extract');
    }
    if (endLine == null) {
      return validationError('endLine', 'endLine is required for extract');
    }
    if (startLine < 1) {
      return validationError('startLine', 'startLine must be >= 1');
    }
    if (endLine < 1) {
      return validationError('endLine', 'endLine must be >= 1');
    }
    if (endLine < startLine) {
      return validationError('endLine', 'endLine must be >= startLine');
    }
    if (insertAt != null && insertAt < 1) {
      return validationError('insert_at', 'insert_at must be >= 1');
    }

    // 2. Validate source path
    final sourcePathError = validateRelativePath(sourcePath);
    if (sourcePathError != null) {
      return validationError('path', '$sourcePathError. $_allowedPathsHint');
    }
    final absSourcePath = getAbsolutePath(workingDir, sourcePath);
    if (!isAllowedPath(allowedPaths, absSourcePath)) {
      return validationError(
          'path', 'Not allowed for: $sourcePath. $_allowedPathsHint');
    }

    // 3. Validate destination path
    final destPathError = validateRelativePath(destinationPath!);
    if (destPathError != null) {
      return validationError(
          'destination', '$destPathError. $_allowedPathsHint');
    }
    final absDestPath = getAbsolutePath(workingDir, destinationPath);
    if (!isAllowedPath(allowedPaths, absDestPath)) {
      return validationError(
          'destination',
          'Not allowed for: $destinationPath. $_allowedPathsHint');
    }

    // 4. Read source file
    final sourceFile = File(absSourcePath);
    if (!await sourceFile.exists()) {
      return notFoundError('File', sourcePath);
    }

    final sourceContent = await sourceFile.readAsString();
    final sourceLineEnding = sourceContent.isNotEmpty
        ? detectLineEndings(sourceContent)
        : '\n';
    final normalizedSource = normalizeLineEndings(sourceContent);
    final sourceLines = normalizedSource.split('\n');

    // 5. Validate line range against source
    if (startLine > sourceLines.length) {
      return validationError(
        'startLine',
        'startLine ($startLine) exceeds file length (${sourceLines.length} lines)',
      );
    }
    final actualEndLine =
        endLine > sourceLines.length ? sourceLines.length : endLine;

    // 6. Extract lines (1-indexed to 0-indexed)
    final extractedLines =
        sourceLines.sublist(startLine - 1, actualEndLine);
    final extractedCount = extractedLines.length;

    // 7. Handle destination file
    final destFile = File(absDestPath);
    final destExists = await destFile.exists();

    String destLineEnding;
    List<String> destLines;

    if (destExists) {
      final destContent = await destFile.readAsString();
      destLineEnding = destContent.isNotEmpty
          ? detectLineEndings(destContent)
          : sourceLineEnding;
      destLines = normalizeLineEndings(destContent).split('\n');
    } else {
      destLineEnding = sourceLineEnding;
      destLines = <String>[];
    }

    // Insert extracted lines into destination
    if (insertAt != null) {
      final insertIndex = insertAt - 1;
      if (insertIndex > destLines.length) {
        // Pad with empty lines if needed
        final padding =
            List.filled(insertIndex - destLines.length, '');
        destLines.addAll(padding);
      }
      destLines.insertAll(insertIndex, extractedLines);
    } else if (destExists) {
      // Append to existing file
      destLines.addAll(extractedLines);
    } else {
      // New file — just use extracted lines
      destLines = extractedLines;
    }

    // Write destination file (create parent dirs if needed)
    if (!destExists) {
      await destFile.create(recursive: true);
    }
    final destResult = destLines.join('\n');
    await destFile.writeAsString(
        applyLineEndings(destResult, destLineEnding));

    // 8. Remove from source if requested
    if (removeFromSource) {
      sourceLines.removeRange(startLine - 1, actualEndLine);
      final sourceResult = sourceLines.join('\n');
      await sourceFile.writeAsString(
          applyLineEndings(sourceResult, sourceLineEnding));
    }

    // 9. Return summary
    final action = removeFromSource ? 'removed from source' : 'kept in source';
    final destAction = destExists
        ? (insertAt != null
            ? 'inserted at line $insertAt'
            : 'appended')
        : 'new file created';
    return textResult(
      'Extracted lines $startLine-$actualEndLine from $sourcePath → '
      '$destinationPath ($extractedCount lines, $action, $destAction)',
    );
  }
}