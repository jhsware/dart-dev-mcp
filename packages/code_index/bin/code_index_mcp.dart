import 'dart:io';

import 'package:code_index_mcp/code_index_mcp.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Code Index MCP Server
///
/// Maintains a searchable index of programming code files in a project.
/// Stores data in a SQLite database and allows quick file discovery.
///
/// Usage: `dart run bin/code_index_mcp.dart --db-path=PATH --project-dir=PATH`
void main(List<String> arguments) async {
  String? dbPath;
  String? projectDir;

  // Parse arguments
  for (final arg in arguments) {
    if (arg.startsWith('--db-path=')) {
      dbPath = arg.substring('--db-path='.length);
    } else if (arg.startsWith('--project-dir=')) {
      projectDir = arg.substring('--project-dir='.length);
    } else if (arg == '--help' || arg == '-h') {
      _printUsage();
      exit(0);
    }
  }

  // Validate required arguments
  if (dbPath == null || dbPath.isEmpty) {
    stderr.writeln('Error: --db-path is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  if (projectDir == null || projectDir.isEmpty) {
    stderr.writeln('Error: --project-dir is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  final workingDir = Directory(p.normalize(p.absolute(projectDir)));

  if (!await workingDir.exists()) {
    stderr.writeln('Error: Project path does not exist: $projectDir');
    exit(1);
  }

  // Initialize database
  final database = initializeDatabase(dbPath);

  // Create operation handlers
  final indexOps = IndexOperations(
    database: database,
    workingDir: workingDir,
  );
  final searchOps = SearchOperations(database: database);
  final diffOps = DiffOperations(
    database: database,
    workingDir: workingDir,
  );

  logInfo('code-index', 'Code Index MCP Server starting...');
  logInfo('code-index', 'Project path: ${workingDir.path}');
  logInfo('code-index', 'Database: $dbPath');

  // Set up graceful shutdown to close database
  setupShutdownHandlers(database);

  final server = McpServer(
    Implementation(name: 'code-index-mcp', version: '1.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the code-index tool
  server.tool(
    'code-index',
    description: '''Maintains a searchable index of code files in a project.

Operations:
- index-file: Add or update a file entry in the code index
- search: Search the index for files matching criteria
- diff: Scan directories and report changed/added/deleted files''',
    toolInputSchema: ToolInputSchema(
      properties: {
        'operation': {
          'type': 'string',
          'description': 'The operation to perform',
          'enum': _validOperations,
        },
        // index-file parameters
        'path': {
          'type': 'string',
          'description':
              'Relative path from project root (for index-file)',
        },
        'name': {
          'type': 'string',
          'description': 'File name (for index-file)',
        },
        'description': {
          'type': 'string',
          'description': 'Description of what the file does (for index-file)',
        },
        'file_type': {
          'type': 'string',
          'description':
              'File type e.g. "dart", "yaml", "json" (for index-file, search)',
        },
        'exports': {
          'type': 'array',
          'description':
              'Exported symbols (for index-file). Each item: {name, kind, parameters?, description?, parent_name?}',
          'items': {
            'type': 'object',
          },
        },
        'variables': {
          'type': 'array',
          'description':
              'Exported variables (for index-file). Each item: {name, description?}',
          'items': {
            'type': 'object',
          },
        },
        'imports': {
          'type': 'array',
          'description': 'Import paths (for index-file)',
          'items': {
            'type': 'string',
          },
        },
        // search parameters
        'query': {
          'type': 'string',
          'description':
              'General text search across file names, descriptions, export names, variable names (for search)',
        },
        'name_pattern': {
          'type': 'string',
          'description': 'Filter by file name pattern (for search)',
        },
        'export_name': {
          'type': 'string',
          'description':
              'Search for files exporting a specific name (for search)',
        },
        'export_kind': {
          'type': 'string',
          'description':
              'Filter exports by kind: class, method, function, class_member, enum, typedef, extension, mixin (for search)',
        },
        'import_pattern': {
          'type': 'string',
          'description': 'Search by import path pattern (for search)',
        },
        'path_pattern': {
          'type': 'string',
          'description': 'Filter by file path pattern (for search)',
        },
        'description_pattern': {
          'type': 'string',
          'description': 'Search in file descriptions (for search)',
        },
        'limit': {
          'type': 'integer',
          'description': 'Max results (for search, default 50)',
        },
        // diff parameters
        'directories': {
          'type': 'array',
          'description':
              'Directories to scan, relative to project root (for diff)',
          'items': {
            'type': 'string',
          },
        },
        'file_extensions': {
          'type': 'array',
          'description':
              'File extensions to include e.g. [".dart", ".yaml"] (for diff)',
          'items': {
            'type': 'string',
          },
        },
        'remove_deleted': {
          'type': 'boolean',
          'description':
              'Auto-remove deleted files from index (for diff, default true)',
        },
      },
    ),
    callback: ({args, extra}) =>
        _handleCodeIndex(args, database, indexOps, searchOps, diffOps),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('code-index', 'Code Index MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln(
      'Usage: code_index_mcp --db-path=PATH --project-dir=PATH');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln(
      '  --db-path=PATH      Path to the SQLite database file (required)');
  stderr.writeln(
      '  --project-dir=PATH  Path to the project directory (required)');
  stderr.writeln('  --help, -h          Show this help message');
}

const _validOperations = ['index-file', 'search', 'diff'];

Future<CallToolResult> _handleCodeIndex(
  Map<String, dynamic>? args,
  Database database,
  IndexOperations indexOps,
  SearchOperations searchOps,
  DiffOperations diffOps,
) async {
  final operation = args?['operation'] as String?;

  if (requireStringOneOf(operation, 'operation', _validOperations)
      case final error?) {
    return error;
  }

  try {
    switch (operation) {
      case 'index-file':
        return indexOps.indexFile(args);
      case 'search':
        return searchOps.search(args);
      case 'diff':
        return diffOps.diff(args);
      default:
        return validationError('operation', 'Unknown operation: $operation');
    }
  } on SqliteException catch (e) {
    final category = classifyError(e);
    final userMessage = userFriendlyMessage(category, e.message);

    logError('code-index:$operation', e, null, {
      'category': category.toString(),
      'resultCode': e.resultCode,
      'extendedResultCode': e.extendedResultCode,
    });

    if (category == SqliteErrorCategory.corruption) {
      logWarning('code-index',
          'CRITICAL: Database corruption detected. Database may need repair.');
    }

    return textResult('Error: $userMessage');
  } catch (e, stackTrace) {
    return errorResult('code-index:$operation', e, stackTrace, {
      'operation': operation,
    });
  }
}
