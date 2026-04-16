import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:filesystem_mcp/filesystem_mcp.dart';

/// File System MCP Server
///
/// Provides file system operations with restricted access to allowed paths.
/// Allowed paths are resolved from jhsware-code.yaml per project.
///
/// Usage: `dart run bin/file_edit_mcp.dart --project-dir=PATH1 [--project-dir=PATH2 ...]`
void main(List<String> arguments) async {
  final serverArgs = ServerArguments.parse(arguments);

  if (serverArgs.helpRequested) {
    _printUsage();
    exit(0);
  }

  // Validate required arguments
  if (serverArgs.projectDirs.isEmpty) {
    stderr.writeln('Error: at least one --project-dir is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  // Validate all project directories exist
  for (final dir in serverArgs.projectDirs) {
    final workingDir = Directory(dir);
    if (!await workingDir.exists()) {
      stderr.writeln('Error: Project directory does not exist: $dir');
      exit(1);
    }
  }

  logInfo('fs', 'File Edit MCP Server starting...');
  logInfo('fs', 'Project dirs: ${serverArgs.projectDirs.join(", ")}');

  final server = McpServer(
    Implementation(name: 'file-edit-mcp', version: '1.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the file system tool
  server.registerTool(
    'filesystem',
    description: '''File system operations for reading and editing files.

Operations:
- list-content: Recursively list files and directories
- read-file: Read a single file with line numbers (supports startLine/endLine for partial reads)
- read-files: Read multiple files (comma-separated paths)
- search-text: Search for text pattern (regex) in files
- create-directory: Create a new directory
- create-file: Create a new file with content
- edit-file: Edit file content (overwrite, insert, or replace lines)
- extract: Extract lines from one file and insert into another (cut/copy refactoring without passing content to LLM)''',
    inputSchema: ToolInputSchema(
      properties: {
        'project_dir': JsonSchema.string(
          description:
              'Project directory path. Must match one of the registered --project-dir values. REQUIRED for all operations.',
        ),
        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: _validOperations,
        ),
        'path': JsonSchema.string(
          description:
              'Relative path to file or directory (comma-separated for read-files)',
        ),
        'content': JsonSchema.string(
          description: 'Content for create-file or edit-file operations',
        ),
        'pattern': JsonSchema.string(
          description: 'Regex pattern for search-text operation',
        ),
        'file-pattern': JsonSchema.string(
          description:
              'Glob pattern to filter files (e.g., "*.dart"). Default: all files',
        ),
        'case-sensitive': JsonSchema.boolean(
          description: 'Whether search is case-sensitive. Default: true',
        ),
        'startLine': JsonSchema.integer(
          description:
              '''Starting line number (1-indexed). Used by read-file and edit-file.
For read-file:
- If not provided: reads entire file
- If provided without endLine: reads from startLine to end of file
- If provided with endLine: reads lines startLine to endLine
For edit-file:
- If not provided: overwrites entire file
- If provided without endLine: inserts at this line
- If provided with endLine: replaces lines startLine to endLine''',
        ),
        'endLine': JsonSchema.integer(
          description:
              'Ending line number (1-indexed, inclusive). Used by read-file and edit-file.',
        ),
        'destination': JsonSchema.string(
          description:
              'Destination file path for extract operation (relative path)',
        ),
        'insert_at': JsonSchema.integer(
          description:
              'Line number in destination file to insert at (1-indexed). For extract: omit to append to existing file or write from start of new file',
        ),
        'remove_from_source': JsonSchema.boolean(
          description:
              'For extract: whether to remove extracted lines from source file. Default: true (cut). Set false to copy.',
        ),
      },
      required: ['project_dir'],
    ),
    callback: (args, extra) => _handleFileSystem(args, serverArgs),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('fs', 'File Edit MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln(
      'Usage: file_edit_mcp --project-dir=PATH1 [--project-dir=PATH2 ...]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln(
      '  --project-dir=PATH  Path to a project directory (required, can be repeated)');
  stderr.writeln('  --help, -h          Show this help message');
  stderr.writeln('');
  stderr.writeln(
      'Allowed paths are resolved from jhsware-code.yaml in each project directory.');
}

const _validOperations = [
  'list-content',
  'read-file',
  'read-files',
  'search-text',
  'create-directory',
  'create-file',
  'edit-file',
  'extract',
];

Future<CallToolResult> _handleFileSystem(
  Map<String, dynamic> args,
  ServerArguments serverArgs,
) async {
  // Validate project_dir is present and valid
  final projectDir = args['project_dir'] as String?;
  if (requireString(projectDir, 'project_dir') case final error?) {
    return error;
  }
  if (!serverArgs.projectDirs.contains(projectDir)) {
    return validationError('project_dir',
        'project_dir must be one of: ${serverArgs.projectDirs.join(", ")}');
  }

  final operation = args['operation'] as String?;
  final path = args['path'] as String? ?? '.';

  if (requireStringOneOf(operation, 'operation', _validOperations)
      case final error?) {
    return error;
  }

  // Resolve allowed paths from ProjectConfigService
  final workingDir = Directory(projectDir!);
  final allowedPaths =
      ProjectConfigService.getAllowedPaths(projectDir, 'filesystem');

  // Create operation handlers for this project
  final readOps = FileReadOperations(
    workingDir: workingDir,
    allowedPaths: allowedPaths,
  );
  final writeOps = FileWriteOperations(
    workingDir: workingDir,
    allowedPaths: allowedPaths,
  );

  try {
    switch (operation) {
      case 'list-content':
        return await readOps.listContent(path);
      case 'read-file':
        final startLine = args['startLine'] as int?;
        final endLine = args['endLine'] as int?;
        return await readOps.readFile(path,
            startLine: startLine, endLine: endLine);
      case 'read-files':
        return await readOps.readFiles(path.split(','));
      case 'search-text':
        final pattern = args['pattern'] as String?;
        final filePattern = args['file-pattern'] as String?;
        final caseSensitive = args['case-sensitive'] as bool? ?? true;
        return await readOps.searchText(
            path, pattern, filePattern, caseSensitive);
      case 'create-directory':
        return await writeOps.createDirectory(path);
      case 'create-file':
        final content = args['content'] as String?;
        return await writeOps.createFile(path, content);
      case 'edit-file':
        final content = args['content'] as String?;
        final startLine = args['startLine'] as int?;
        final endLine = args['endLine'] as int?;
        return await writeOps.editFile(path, content, startLine, endLine);
      case 'extract':
        final destination = args['destination'] as String?;
        final startLine = args['startLine'] as int?;
        final endLine = args['endLine'] as int?;
        final insertAt = args['insert_at'] as int?;
        final removeFromSource = args['remove_from_source'] as bool? ?? true;
        return await writeOps.extractLines(
          path,
          destination,
          startLine,
          endLine,
          insertAt,
          removeFromSource,
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
