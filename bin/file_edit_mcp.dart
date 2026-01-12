import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:path/path.dart' as p;

/// File System MCP Server
///
/// Provides file system operations with restricted access to allowed paths.
///
/// Usage: `dart run bin/file_edit_mcp.dart --project-dir=PATH <allowed_path1> [allowed_path2] ...`
void main(List<String> arguments) async {
  String? projectDir;
  final allowedPathArgs = <String>[];

  // Parse arguments
  for (final arg in arguments) {
    if (arg.startsWith('--project-dir=')) {
      projectDir = arg.substring('--project-dir='.length);
    } else if (arg == '--help' || arg == '-h') {
      _printUsage();
      exit(0);
    } else if (!arg.startsWith('-')) {
      allowedPathArgs.add(arg);
    }
  }

  // Validate required arguments
  if (projectDir == null || projectDir.isEmpty) {
    stderr.writeln('Error: --project-dir is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  if (allowedPathArgs.isEmpty) {
    stderr.writeln('Error: At least one allowed path is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  final workingDir = Directory(p.normalize(p.absolute(projectDir)));

  if (!await workingDir.exists()) {
    stderr.writeln('Error: Project directory does not exist: $projectDir');
    exit(1);
  }

  // Convert allowed paths to absolute paths
  final allowedPaths = <String>[];
  for (final arg in allowedPathArgs) {
    final absolutePath = p.isAbsolute(arg)
        ? p.normalize(arg)
        : p.normalize(p.join(workingDir.path, arg));
    
    final dir = Directory(absolutePath);
    final file = File(absolutePath);
    
    final dirExists = await dir.exists();
    final fileExists = await file.exists();
    
    if (!dirExists && !fileExists) {
      logWarning('fs', 'Path does not exist: $arg');
    }
    
    allowedPaths.add(absolutePath);
  }

  if (allowedPaths.isEmpty) {
    stderr.writeln('Error: No valid paths provided');
    exit(1);
  }

  logInfo('fs', 'File Edit MCP Server starting...');
  logInfo('fs', 'Project directory: ${workingDir.path}');
  logInfo('fs', 'Allowed paths: ${allowedPaths.join(", ")}');

  final server = McpServer(
    Implementation(name: 'file-edit-mcp', version: '1.0.0'),
    options: ServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the file system tool
  server.tool(
    'filesystem',
    description: '''File system operations for reading and editing files.

Operations:
- list-content: Recursively list files and directories
- read-file: Read a single file with line numbers
- read-files: Read multiple files (comma-separated paths)
- search-text: Search for text pattern (regex) in files
- create-directory: Create a new directory
- create-file: Create a new file with content
- edit-file: Edit file content (overwrite, insert, or replace lines)''',
    toolInputSchema: ToolInputSchema(
      properties: {
        'operation': {
          'type': 'string',
          'description': 'The operation to perform',
          'enum': [
            'list-content',
            'read-file',
            'read-files',
            'search-text',
            'create-directory',
            'create-file',
            'edit-file',
          ],
        },
        'path': {
          'type': 'string',
          'description':
              'Relative path to file or directory (comma-separated for read-files)',
        },
        'content': {
          'type': 'string',
          'description': 'Content for create-file or edit-file operations',
        },
        'pattern': {
          'type': 'string',
          'description': 'Regex pattern for search-text operation',
        },
        'file-pattern': {
          'type': 'string',
          'description':
              'Glob pattern to filter files (e.g., "*.dart"). Default: all files',
        },
        'case-sensitive': {
          'type': 'boolean',
          'description': 'Whether search is case-sensitive. Default: true',
        },
        'startLine': {
          'type': 'integer',
          'description': '''For edit-file: starting line number (1-indexed).
- If not provided: overwrites entire file
- If provided without endLine: inserts at this line
- If provided with endLine: replaces lines startLine to endLine''',
        },
        'endLine': {
          'type': 'integer',
          'description':
              'For edit-file: ending line number (1-indexed, inclusive)',
        },
      },
    ),
    callback: ({args, extra}) => _handleFileSystem(args, workingDir, allowedPaths),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('fs', 'File Edit MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln('Usage: file_edit_mcp --project-dir=PATH <allowed_path1> [allowed_path2] ...');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln('  --project-dir=PATH  Working directory for the project (required)');
  stderr.writeln('  --help, -h          Show this help message');
  stderr.writeln('');
  stderr.writeln('Arguments:');
  stderr.writeln('  allowed_paths       Paths that can be accessed (relative to project-dir)');
}

const _validOperations = [
  'list-content',
  'read-file',
  'read-files',
  'search-text',
  'create-directory',
  'create-file',
  'edit-file',
];

Future<CallToolResult> _handleFileSystem(
  Map<String, dynamic>? args,
  Directory workingDir,
  List<String> allowedPaths,
) async {
  final operation = args?['operation'] as String?;
  final path = args?['path'] as String? ?? '.';

  if (requireStringOneOf(operation, 'operation', _validOperations) case final error?) {
    return error;
  }

  try {
    switch (operation) {
      case 'list-content':
        return await _listContent(workingDir, path, allowedPaths);
      case 'read-file':
        return await _readFile(workingDir, path, allowedPaths);
      case 'read-files':
        return await _readFiles(workingDir, path.split(','), allowedPaths);
      case 'search-text':
        final pattern = args?['pattern'] as String?;
        final filePattern = args?['file-pattern'] as String?;
        final caseSensitive = args?['case-sensitive'] as bool? ?? true;
        return await _searchText(
          workingDir,
          path,
          pattern,
          filePattern,
          caseSensitive,
          allowedPaths,
        );
      case 'create-directory':
        return await _createDirectory(workingDir, path, allowedPaths);
      case 'create-file':
        final content = args?['content'] as String?;
        return await _createFile(workingDir, path, content, allowedPaths);
      case 'edit-file':
        final content = args?['content'] as String?;
        final startLine = args?['startLine'] as int?;
        final endLine = args?['endLine'] as int?;
        return await _editFile(
          workingDir,
          path,
          content,
          startLine,
          endLine,
          allowedPaths,
        );
      default:
        return validationError('operation', 'Unknown operation: $operation');
    }
  } catch (e, stackTrace) {
    return errorResult('fs:$operation', e, stackTrace, {
      'operation': operation,
      'path': path,
    });
  }
}

// ============================================================================
// Read Operations
// ============================================================================

Future<CallToolResult> _listContent(
  Directory workingDir,
  String path,
  List<String> allowedPaths,
) async {
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

Future<CallToolResult> _readFile(
  Directory workingDir,
  String path,
  List<String> allowedPaths,
) async {
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

Future<CallToolResult> _readFiles(
  Directory workingDir,
  List<String> paths,
  List<String> allowedPaths,
) async {
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

Future<CallToolResult> _searchText(
  Directory workingDir,
  String path,
  String? pattern,
  String? filePattern,
  bool caseSensitive,
  List<String> allowedPaths,
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
      workingDir,
      dirPath,
      path,
      pattern,
      filePattern,
      caseSensitive,
    );
  } catch (e) {
    return await _searchWithDart(
      workingDir,
      dirPath,
      path,
      regex,
      filePattern,
    );
  }
}

Future<CallToolResult> _searchWithGrep(
  Directory workingDir,
  String dirPath,
  String basePath,
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
  Directory workingDir,
  String dirPath,
  String basePath,
  RegExp regex,
  String? filePattern,
) async {
  final fileRegex = filePattern != null ? _globToRegex(filePattern) : null;
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

RegExp _globToRegex(String glob) {
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

// ============================================================================
// Write Operations
// ============================================================================

Future<CallToolResult> _createDirectory(
  Directory workingDir,
  String path,
  List<String> allowedPaths,
) async {
  final pathError = validateRelativePath(path);
  if (pathError != null) {
    return validationError('path', pathError);
  }

  final dirPath = getAbsolutePath(workingDir, path);
  if (!isAllowedPath(allowedPaths, dirPath)) {
    return validationError('path', 'Not allowed for: $path');
  }

  final directory = Directory(dirPath);
  if (await directory.exists()) {
    return textResult('Directory already exists: $path');
  }

  await directory.create(recursive: true);
  return textResult('Created directory: $path');
}

Future<CallToolResult> _createFile(
  Directory workingDir,
  String path,
  String? content,
  List<String> allowedPaths,
) async {
  final pathError = validateRelativePath(path);
  if (pathError != null) {
    return validationError('path', pathError);
  }

  final filePath = getAbsolutePath(workingDir, path);
  if (!isAllowedPath(allowedPaths, filePath)) {
    return validationError('path', 'Not allowed for: $path');
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

Future<CallToolResult> _editFile(
  Directory workingDir,
  String path,
  String? content,
  int? startLine,
  int? endLine,
  List<String> allowedPaths,
) async {
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
