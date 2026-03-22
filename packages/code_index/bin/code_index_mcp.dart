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
/// Usage: `dart run bin/code_index_mcp.dart --db-path=PATH [--project-dir=PATH [allowed_path1] ...]`
///
/// When project_root is passed as a tool call parameter, allowed paths are
/// read from jhsware-code.yaml in that project root. CLI args serve as fallback.
void main(List<String> arguments) async {
  String? dbPath;
  String? projectDir;
  final allowedPathArgs = <String>[];

  // Parse arguments
  for (final arg in arguments) {
    if (arg.startsWith('--db-path=')) {
      dbPath = arg.substring('--db-path='.length);
    } else if (arg.startsWith('--project-dir=')) {
      projectDir = arg.substring('--project-dir='.length);
    } else if (arg == '--help' || arg == '-h') {
      _printUsage();
      exit(0);
    } else if (!arg.startsWith('-')) {
      allowedPathArgs.add(arg);
    }
  }

  // Validate required arguments
  if (dbPath == null || dbPath.isEmpty) {
    stderr.writeln('Error: --db-path is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  // CLI-provided defaults (used as fallback when project_root not in tool call)
  Directory? cliWorkingDir;
  List<String> cliAllowedPaths = [];

  if (projectDir != null && projectDir.isNotEmpty) {
    cliWorkingDir = Directory(p.normalize(p.absolute(projectDir)));

    if (!await cliWorkingDir.exists()) {
      stderr.writeln('Error: Project path does not exist: $projectDir');
      exit(1);
    }

    // Convert allowed paths to absolute paths
    for (final arg in allowedPathArgs) {
      final absolutePath = p.isAbsolute(arg)
          ? p.normalize(arg)
          : p.normalize(p.join(cliWorkingDir.path, arg));

      final dir = Directory(absolutePath);
      final file = File(absolutePath);

      final dirExists = await dir.exists();
      final fileExists = await file.exists();

      if (!dirExists && !fileExists) {
        logWarning('code-index', 'Path does not exist: $arg');
      }

      cliAllowedPaths.add(absolutePath);
    }
  }

  // Initialize database
  final database = initializeDatabase(dbPath);

  logInfo('code-index', 'Code Index MCP Server starting...');
  if (cliWorkingDir != null) {
    logInfo('code-index', 'CLI project path: ${cliWorkingDir.path}');
    logInfo('code-index', 'CLI allowed paths: ${cliAllowedPaths.join(", ")}');
  } else {
    logInfo('code-index', 'No CLI project directory set, project_root param required in tool calls');
  }
  logInfo('code-index', 'Database: $dbPath');

  // Set up graceful shutdown to close database
  setupShutdownHandlers(database);

  // Create shared operation handlers (no path restrictions needed)
  final searchOps = SearchOperations(database: database);
  final browseOps = BrowseOperations(database: database);

  final server = McpServer(
    Implementation(name: 'code-index-mcp', version: '1.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the code-index tool
  server.registerTool(
    'code-index',
    description: '''Maintains a searchable index of code files in a project.

Operations:
- index-file: Add or update a file entry in the code index
- auto-index: Automatically read and index a file, extracting all metadata (imports, exports, variables, annotations) programmatically for Dart files
- search: Search the index for files matching criteria
- show-file: Show full indexed information for a specific file
- dependents: Find all files that import a given path
- dependencies: Get all imports for a file with internal/external classification
- search-annotations: Search TODO/FIXME/HACK annotations across the codebase
- stats: Get aggregate statistics about the code index (files, exports, imports, annotations)
- diff: Scan directories and report changed/added/deleted files
- overview: Get a compact overview of all indexed files with descriptions and export names
- file-summary: Show a file's exports grouped by class and variables, without heavy metadata''',
    inputSchema: ToolInputSchema(
      properties: {
        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: _validOperations,
        ),
        // index-file parameters
        'path': JsonSchema.string(
          description:
              'Relative path from project root (for index-file, show-file, dependents, dependencies)',
        ),
        'name': JsonSchema.string(
          description: 'File name (for index-file)',
        ),
        'description': JsonSchema.string(
          description: 'Description of what the file does (for index-file)',
        ),
        'file_type': JsonSchema.string(
          description:
              'File type e.g. "dart", "yaml", "json" (for index-file, search)',
        ),
        'exports': JsonSchema.array(
          items: JsonSchema.object(),
          description:
              'Exported symbols (for index-file). Each item: {name, kind, parameters?, description?, parent_name?}',
        ),
        'variables': JsonSchema.array(
          items: JsonSchema.object(),
          description:
              'Exported variables (for index-file). Each item: {name, description?}',
        ),
        'imports': JsonSchema.array(
          items: JsonSchema.string(),
          description: 'Import paths (for index-file)',
        ),
        'annotations': JsonSchema.array(
          items: JsonSchema.object(),
          description:
              'Code annotations (for index-file). Each item: {kind, message?, line?}. Kinds: TODO, FIXME, HACK, NOTE, DEPRECATED',
        ),
        // search parameters
        'query': JsonSchema.string(
          description:
              'General text search across file names, descriptions, export names, export descriptions, variable names (for search). Multiple keywords are joined with OR — files matching more keywords rank higher via BM25. Each keyword uses prefix matching (e.g. "add" matches "addTask"). For AND semantics, run separate searches or use other filters.',
        ),
        'name_pattern': JsonSchema.string(
          description: 'Filter by file name pattern (for search)',
        ),
        'export_name': JsonSchema.string(
          description:
              'Search for files exporting a specific name (for search)',
        ),
        'export_kind': JsonSchema.string(
          description:
              'Filter exports by kind: class, method, function, class_member, enum, typedef, extension, mixin (for search)',
        ),
        'import_pattern': JsonSchema.string(
          description: 'Search by import path pattern (for search)',
        ),
        'path_pattern': JsonSchema.string(
          description: 'Filter by file path pattern (for search)',
        ),
        'description_pattern': JsonSchema.string(
          description: 'Search in file descriptions (for search)',
        ),
        'limit': JsonSchema.integer(
          description: 'Max results (for search, search-annotations, default 50)',
        ),
        // search-annotations parameters
        'kind': JsonSchema.string(
          description:
              'Annotation kind filter: TODO, FIXME, HACK, NOTE, DEPRECATED (for search-annotations)',
        ),
        'message_pattern': JsonSchema.string(
          description: 'Search in annotation messages (for search-annotations)',
        ),
        // diff parameters
        'directories': JsonSchema.array(
          items: JsonSchema.string(),
          description:
              'Directories to scan, relative to project root (for diff). Default: ["."]',
        ),
        'file_extensions': JsonSchema.array(
          items: JsonSchema.string(),
          description:
              'File extensions to include e.g. [".dart", ".yaml"] (for diff)',
        ),
        'remove_deleted': JsonSchema.boolean(
          description:
              'Auto-remove deleted files from index (for diff, default true)',
        ),
      },
    ),
    callback: (args, extra) =>
        _handleCodeIndex(args, database, cliWorkingDir, cliAllowedPaths, searchOps, browseOps),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('code-index', 'Code Index MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln(
      'Usage: code_index_mcp --db-path=PATH [--project-dir=PATH [allowed_path1] ...]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln(
      '  --db-path=PATH      Path to the SQLite database file (required)');
  stderr.writeln(
      '  --project-dir=PATH  Path to the project directory (fallback)');
  stderr.writeln('  --help, -h          Show this help message');
  stderr.writeln('');
  stderr.writeln('Arguments:');
  stderr.writeln('  allowed_paths       Paths that can be indexed (relative to project-dir)');
  stderr.writeln('');
  stderr.writeln('Note: When project_root is provided in a tool call, allowed paths');
  stderr.writeln('are read from jhsware-code.yaml in that project root instead.');
}

const _validOperations = ['index-file', 'auto-index', 'search', 'show-file', 'dependents', 'dependencies', 'search-annotations', 'stats', 'diff', 'overview', 'file-summary'];

/// Resolve workingDir and allowedPaths from project_root parameter or CLI fallback.
({Directory workingDir, List<String> allowedPaths})? _resolveProjectContext(
  Map<String, dynamic> args,
  Directory? cliWorkingDir,
  List<String> cliAllowedPaths,
  String toolName,
) {
  final projectRoot = args['project_root'] as String?;

  if (projectRoot != null && projectRoot.isNotEmpty) {
    final absRoot = p.normalize(p.absolute(projectRoot));
    final workingDir = Directory(absRoot);
    final allowedPaths = ProjectConfigService.getAllowedPaths(absRoot, toolName);
    return (workingDir: workingDir, allowedPaths: allowedPaths);
  }

  if (cliWorkingDir != null) {
    return (workingDir: cliWorkingDir, allowedPaths: cliAllowedPaths);
  }

  return null;
}

/// Operations that require a project context (workingDir + allowedPaths)
const _pathRequiredOperations = ['index-file', 'auto-index', 'diff'];

Future<CallToolResult> _handleCodeIndex(
  Map<String, dynamic> args,
  Database database,
  Directory? cliWorkingDir,
  List<String> cliAllowedPaths,
  SearchOperations searchOps,
  BrowseOperations browseOps,
) async {
  final operation = args['operation'] as String?;

  if (requireStringOneOf(operation, 'operation', _validOperations)
      case final error?) {
    return error;
  }

  try {
    // Operations that need project context (workingDir + allowedPaths)
    if (_pathRequiredOperations.contains(operation)) {
      final context = _resolveProjectContext(args, cliWorkingDir, cliAllowedPaths, 'code_index');
      if (context == null) {
        return validationError('project_root',
            'No project_root provided and no CLI --project-dir configured. '
            'Either pass project_root in the tool call or start the server with --project-dir.');
      }

      final indexOps = IndexOperations(
        database: database,
        workingDir: context.workingDir,
        allowedPaths: context.allowedPaths,
      );
      final diffOps = DiffOperations(
        database: database,
        workingDir: context.workingDir,
        allowedPaths: context.allowedPaths,
      );

      switch (operation) {
        case 'index-file':
          return indexOps.indexFile(args);
        case 'auto-index':
          return indexOps.autoIndex(args);
        case 'diff':
          return diffOps.diff(args);
        default:
          return validationError('operation', 'Unknown operation: $operation');
      }
    }

    // Operations that only need the database (no path restrictions)
    switch (operation) {
      case 'search':
        return searchOps.search(args);
      case 'show-file':
        return browseOps.showFile(args);
      case 'dependents':
        return searchOps.dependents(args);
      case 'dependencies':
        return searchOps.dependencies(args);
      case 'search-annotations':
        return searchOps.searchAnnotations(args);
      case 'stats':
        return searchOps.stats(args);
      case 'overview':
        return browseOps.overview(args);
      case 'file-summary':
        return browseOps.fileSummary(args);
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
