import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:filesystem_mcp/filesystem_mcp.dart';
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

  // Create operation handlers
  final readOps = FileReadOperations(
    workingDir: workingDir,
    allowedPaths: allowedPaths,
  );
  final writeOps = FileWriteOperations(
    workingDir: workingDir,
    allowedPaths: allowedPaths,
  );

  logInfo('fs', 'File Edit MCP Server starting...');
  logInfo('fs', 'Project directory: ${workingDir.path}');
  logInfo('fs', 'Allowed paths: ${allowedPaths.join(", ")}');

  final server = McpServer(
    Implementation(name: 'file-edit-mcp', version: '1.0.0'),
    options: McpServerOptions(
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
          'enum': _validOperations,
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
    callback: ({args, extra}) => _handleFileSystem(args, readOps, writeOps),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('fs', 'File Edit MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln(
      'Usage: file_edit_mcp --project-dir=PATH <allowed_path1> [allowed_path2] ...');
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
  FileReadOperations readOps,
  FileWriteOperations writeOps,
) async {
  final operation = args?['operation'] as String?;
  final path = args?['path'] as String? ?? '.';

  if (requireStringOneOf(operation, 'operation', _validOperations)
      case final error?) {
    return error;
  }

  try {
    switch (operation) {
      case 'list-content':
        return await readOps.listContent(path);
      case 'read-file':
        return await readOps.readFile(path);
      case 'read-files':
        return await readOps.readFiles(path.split(','));
      case 'search-text':
        final pattern = args?['pattern'] as String?;
        final filePattern = args?['file-pattern'] as String?;
        final caseSensitive = args?['case-sensitive'] as bool? ?? true;
        return await readOps.searchText(path, pattern, filePattern, caseSensitive);
      case 'create-directory':
        return await writeOps.createDirectory(path);
      case 'create-file':
        final content = args?['content'] as String?;
        return await writeOps.createFile(path, content);
      case 'edit-file':
        final content = args?['content'] as String?;
        final startLine = args?['startLine'] as int?;
        final endLine = args?['endLine'] as int?;
        return await writeOps.editFile(path, content, startLine, endLine);
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
