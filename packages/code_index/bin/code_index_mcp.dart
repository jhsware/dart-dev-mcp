import 'dart:io';

import 'package:jhsware_code_code_index/code_index_mcp.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Code Index MCP Server (v2).
///
/// Maintains a layered, searchable index of a project's code files in a
/// standalone SQLite store under `~/.code-index/<basename>-<hash8>` (design
/// §3). Change detection is SHA-256 based; Dart structure (layer 2) is
/// extracted by a warm analyzer kept per project per process.
///
/// Usage: `dart run bin/code_index_mcp.dart --project-dir=PATH1 [--project-dir=PATH2 ...] [--data-root=PATH]`
void main(List<String> arguments) async {
  final serverArgs = ServerArguments.parse(arguments);

  if (serverArgs.helpRequested) {
    _printUsage();
    exit(0);
  }

  if (serverArgs.projectDirs.isEmpty) {
    stderr.writeln('Error: at least one --project-dir is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  // Validate all project directories exist.
  for (final dir in serverArgs.projectDirs) {
    if (!Directory(dir).existsSync()) {
      stderr.writeln('Error: Project path does not exist: $dir');
      exit(1);
    }
  }

  final dataRoot = serverArgs.dataRoot;

  // Per-project cached resources (created on demand).
  final resources = <String, _ProjectResources>{};

  /// Open (or lazily create) the resources for [projectDir]: the standalone
  /// data directory, an open SQLite [Database] (rebuilt on schema drift), and
  /// a warm [DartExtractor]. Stamps `meta.json` on first open and refreshes
  /// the central registry (`last_opened_at`) every call.
  _ProjectResources getResources(String projectDir) {
    final existing = resources[projectDir];
    if (existing != null) {
      // Registry `last_opened_at` refresh is cheap; keep it current.
      upsertProject(dataRoot, projectDir);
      return existing;
    }

    final dataDir = ensureDataDir(dataRoot, projectDir).path;
    // Guard against hash-prefix collisions / manual directory shuffling.
    assertMetaMatches(dataDir, projectDir);

    final dbPath = dbPathFor(dataRoot, projectDir);
    final database = openOrRebuild(dbPath);

    // Stamp the per-project marker on first open.
    if (readMeta(dataDir) == null) {
      writeMeta(dataDir, projectDir, schemaVersion);
    }
    upsertProject(dataRoot, projectDir);

    final res = _ProjectResources(
      database: database,
      extractor: DartExtractor(projectPath: projectDir),
      dbPath: dbPath,
    );
    resources[projectDir] = res;
    return res;
  }

  logInfo('code-index', 'Code Index MCP Server (v2) starting...');
  logInfo('code-index', 'Project dirs: ${serverArgs.projectDirs.join(", ")}');
  logInfo('code-index', 'Data root: $dataRoot');

  // Graceful shutdown: close every open database.
  ProcessSignal.sigint.watch().listen((_) {
    for (final res in resources.values) {
      res.database.dispose();
    }
    exit(0);
  });

  final server = McpServer(
    Implementation(name: 'jhsware_code_code_index', version: '2.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
    ),
  );

  server.registerTool(
    'code-index',
    description:
        '''Maintains a layered, searchable index of code files in a project.

Operations:
- scan: Walk the tree, detect added/changed/deleted files (SHA-256), and return a language-aware indexing plan. Params: directories, extensions, since, rebuild, remove_deleted, verify.
- index-files: Batched write of 1..N file records. Dart layer 2 (declarations, references, annotations) is computed by the warm analyzer; other files carry agent-supplied structure. Refreshes dependents of changed Dart files unless refresh_dependents:false. Params: files[], refresh_dependents.
- get-file: One file, selected layers (default [0,1,4]). 0=metadata, 1=summary+tags, 2=all declarations+imports+references+annotations, 3=+per-symbol summaries, 4=public API only. Returns needs_reindex.
- get-files: Batched get-file with aggregated needs_reindex. Params: paths[], layers.
- overview: Compact orientation listing — path, summary, tags, line_count, public symbol names. Params: path_pattern, file_type, language, limit.
- search: FTS5 across names, paths, summaries, tags, symbols, references (OR + prefix + BM25) with AND filters. Params: query, file_type, language, path_pattern, tag, symbol_name, symbol_kind, import_pattern, limit.
- find-symbol: Resolve a declaration to its file + line range (jump-to-definition). Params: name, match (exact|prefix), kind, visibility, path_pattern, limit.
- references: Which files use a symbol, in dot-path form. Params: symbol, module, source_path, dot_path_pattern, kind, resolution (resolved|declared), path_pattern, limit.
- dependents: Which files import a given path. Params: path.
- dependencies: What a file imports, classified internal/external. Params: path.
- annotations: TODO/FIXME/HACK/NOTE/DEPRECATED queries with by_kind counts. Params: kind, message_pattern, path_pattern, file_type, limit.
- stats: Aggregate counts, tag cloud, and freshness summary. Params: limit.
- project-info: Data dir, db path, registry entry, schema version, row counts, last scan.
- is-allowed: Check if a path is within the allowed paths for this project. Params: path.
- prune-stores: Report stores under the data root whose source project no longer exists on disk; pass delete:true to remove them (default is a dry run). Params: delete.

Git worktrees (<root>/.worktrees/<slug>) share their main checkout's store, so worktree sessions reuse the existing index.''',
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
        // ── file-scoped read params ──────────────────────────────────────
        'path': JsonSchema.string(
          description:
              'Relative path from project root (for get-file, dependents, dependencies, is-allowed)',
        ),
        'paths': JsonSchema.array(
          items: JsonSchema.string(),
          description:
              'List of relative paths from project root (for get-files)',
        ),
        'layers': JsonSchema.array(
          items: JsonSchema.integer(),
          description:
              'Which layers to read (for get-file, get-files). Default [0,1,4]. 0=filesystem metadata, 1=summary+tags, 2=all declarations+imports+references+annotations, 3=+per-symbol summaries, 4=public API only.',
        ),
        // ── index-files (write) params ───────────────────────────────────
        'files': JsonSchema.array(
          items: JsonSchema.object(),
          description:
              'Records to index (for index-files). Each item: {path (required), language?, summary?, tags?, symbol_summaries?, symbols?, imports?, references?, annotations?}. For Dart files, structure is extracted by the analyzer and agent-supplied structure arrays are ignored.',
        ),
        'refresh_dependents': JsonSchema.boolean(
          description:
              'Re-resolve references of Dart files that import the changed Dart files (for index-files, default true).',
        ),
        // ── scan params ──────────────────────────────────────────────────
        'directories': JsonSchema.array(
          items: JsonSchema.string(),
          description:
              'Directories to scan, relative to project root (for scan). Default ["."].',
        ),
        'extensions': JsonSchema.array(
          items: JsonSchema.string(),
          description:
              'File extensions to include e.g. [".dart", ".yaml"] (for scan).',
        ),
        'since': JsonSchema.string(
          description:
              'ISO 8601 timestamp. Files with mtime older than this are skipped without hashing (for scan). Useful for incremental scans.',
        ),
        'rebuild': JsonSchema.boolean(
          description:
              'Drop and recreate the database before scanning (for scan, default false). Every file will appear as added.',
        ),
        'remove_deleted': JsonSchema.boolean(
          description:
              'Auto-remove deleted files from the index (for scan, default true).',
        ),
        'verify': JsonSchema.boolean(
          description:
              'Force full hashing even when mtime+size are unchanged (for scan, default false).',
        ),
        // ── prune-stores params ──────────────────────────────────────────
        'delete': JsonSchema.boolean(
          description:
              'Actually delete orphaned stores (for prune-stores). Default false = dry-run report.',
        ),
        // ── search params ────────────────────────────────────────────────
        'query': JsonSchema.string(
          description:
              'Full-text query across names, paths, summaries, tags, symbols, and reference dot-paths (for search). Tokens are OR-joined with prefix matching, BM25-ranked. Falls back to LIKE on malformed queries.',
        ),
        'file_type': JsonSchema.string(
          description:
              'Filter by file type e.g. "dart", "yaml" (for search, overview, annotations).',
        ),
        'language': JsonSchema.string(
          description: 'Filter by language (for search, overview).',
        ),
        'path_pattern': JsonSchema.string(
          description:
              'Filter by file path (LIKE) (for search, overview, find-symbol, references, annotations).',
        ),
        'tag': JsonSchema.string(
          description: 'Exact concept-tag match (for search).',
        ),
        'symbol_name': JsonSchema.string(
          description:
              'Files declaring a symbol with this exact name (for search).',
        ),
        'symbol_kind': JsonSchema.string(
          description:
              'Files declaring a symbol of this kind: class, mixin, enum, function, method, constructor, getter, setter, variable, constant, typedef, extension (for search).',
        ),
        'import_pattern': JsonSchema.string(
          description: 'Files whose imports match this pattern (for search).',
        ),
        // ── find-symbol params ───────────────────────────────────────────
        'name': JsonSchema.string(
          description: 'Symbol name to resolve (for find-symbol).',
        ),
        'match': JsonSchema.string(
          description:
              "Symbol name match mode: 'exact' or 'prefix' (for find-symbol, default exact).",
          enumValues: const ['exact', 'prefix'],
        ),
        'visibility': JsonSchema.string(
          description:
              "Filter by visibility: 'public' or 'private' (for find-symbol).",
        ),
        // ── references params ────────────────────────────────────────────
        'symbol': JsonSchema.string(
          description: 'Exact referenced symbol name (for references).',
        ),
        'module': JsonSchema.string(
          description: 'Package/module name filter (for references).',
        ),
        'source_path': JsonSchema.string(
          description: 'Dot-notation source path filter (for references).',
        ),
        'dot_path_pattern': JsonSchema.string(
          description: 'LIKE pattern for the full dot_path (for references).',
        ),
        'resolution': JsonSchema.string(
          description:
              "Reference resolution filter: 'resolved' (analyzer) or 'declared' (agent) (for references).",
          enumValues: const ['resolved', 'declared'],
        ),
        // ── shared: kind (find-symbol / references / annotations) ────────
        'kind': JsonSchema.string(
          description:
              'Symbol kind filter (find-symbol, references). Annotation kind filter: TODO, FIXME, HACK, NOTE, DEPRECATED (annotations).',
        ),
        // ── annotations params ───────────────────────────────────────────
        'message_pattern': JsonSchema.string(
          description:
              'LIKE pattern for annotation messages (for annotations).',
        ),
        // ── shared: limit ────────────────────────────────────────────────
        'limit': JsonSchema.integer(
          description:
              'Max results (for search, find-symbol, references, overview, annotations, stats). Defaults vary by operation.',
        ),
      },
      required: ['project_dir'],
    ),
    callback: (args, extra) => _handleCodeIndex(args, serverArgs, getResources),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('code-index', 'Code Index MCP Server running on stdio');
}

/// Per-project cached resources: an open [Database] plus a warm
/// [DartExtractor]. The database may be swapped after a `rebuild` scan.
class _ProjectResources {
  Database database;
  final DartExtractor extractor;
  final String dbPath;

  _ProjectResources({
    required this.database,
    required this.extractor,
    required this.dbPath,
  });
}

const _validOperations = [
  'scan',
  'index-files',
  'get-file',
  'get-files',
  'overview',
  'search',
  'find-symbol',
  'references',
  'dependents',
  'dependencies',
  'annotations',
  'stats',
  'project-info',
  'is-allowed',
  'prune-stores',
];

const _commonArgs = {'project_dir', 'operation'};

/// Recognized argument keys per operation, enforced via checkUnknownArgs.
final _allowedArgsByOperation = <String, Set<String>>{
  'scan': {
    ..._commonArgs,
    'directories',
    'extensions',
    'since',
    'rebuild',
    'remove_deleted',
    'verify',
  },
  'index-files': {..._commonArgs, 'files', 'refresh_dependents'},
  'get-file': {..._commonArgs, 'path', 'layers'},
  'get-files': {..._commonArgs, 'paths', 'layers'},
  'overview': {
    ..._commonArgs,
    'path_pattern',
    'file_type',
    'language',
    'limit',
  },
  'search': {
    ..._commonArgs,
    'query',
    'file_type',
    'language',
    'path_pattern',
    'tag',
    'symbol_name',
    'symbol_kind',
    'import_pattern',
    'limit',
  },
  'find-symbol': {
    ..._commonArgs,
    'name',
    'match',
    'kind',
    'visibility',
    'path_pattern',
    'limit',
  },
  'references': {
    ..._commonArgs,
    'symbol',
    'module',
    'source_path',
    'dot_path_pattern',
    'kind',
    'resolution',
    'path_pattern',
    'limit',
  },
  'dependents': {..._commonArgs, 'path'},
  'dependencies': {..._commonArgs, 'path'},
  'annotations': {
    ..._commonArgs,
    'kind',
    'message_pattern',
    'path_pattern',
    'file_type',
    'limit',
  },
  'stats': {..._commonArgs, 'limit'},
  'project-info': _commonArgs,
  'is-allowed': {..._commonArgs, 'path'},
  'prune-stores': {..._commonArgs, 'delete'},
};

Future<CallToolResult> _handleCodeIndex(
  Map<String, dynamic> args,
  ServerArguments serverArgs,
  _ProjectResources Function(String projectDir) getResources,
) async {
  // Worktree aliases are accepted: the caller may pass the repository dir
  // when its provisioned worktree is registered, or vice versa (see
  // resolveProjectDirAlias).
  final requestedDir = args['project_dir'] as String?;
  if (requireString(requestedDir, 'project_dir') case final error?) {
    return error;
  }
  final projectDir = resolveProjectDirAlias(
    requestedDir!,
    serverArgs.projectDirs,
  );
  if (projectDir == null) {
    return validationError(
      'project_dir',
      'project_dir must be one of: ${serverArgs.projectDirs.join(", ")}',
    );
  }

  final operation = args['operation'] as String?;
  if (requireStringOneOf(operation, 'operation', _validOperations)
      case final error?) {
    return error;
  }

  // Reject unknown or misspelled arguments before dispatch — a silently
  // ignored argument would change the operation's behavior (e.g. a
  // misspelled remove_deleted on scan would let deletions proceed).
  if (checkUnknownArgs(args, operation!, _allowedArgsByOperation[operation]!)
      case final error?) {
    return error;
  }

  final workingDir = Directory(projectDir);
  final allowedPaths = ProjectConfigService.getAllowedPaths(
    projectDir,
    'code-index',
  );

  // `is-allowed` needs no database.
  if (operation == 'is-allowed') {
    final path = args['path'] as String?;
    if (requireString(path, 'path') case final error?) {
      return error;
    }
    final relativePaths = getAllowedRelativePaths(workingDir, allowedPaths);
    if (allowedPaths.isEmpty) {
      return jsonResult({
        'allowed': true,
        'path': path,
        'allowed_paths': relativePaths,
      });
    }
    final absolutePath = p.normalize(p.join(workingDir.path, path!));
    return jsonResult({
      'allowed': isAllowedPath(allowedPaths, absolutePath),
      'path': path,
      'allowed_paths': relativePaths,
    });
  }

  // `prune-stores` operates on the data root as a whole, not a project
  // database — handle it before opening project resources.
  if (operation == 'prune-stores') {
    final delete = args['delete'] as bool? ?? false;
    return jsonResult(pruneOrphanedStores(serverArgs.dataRoot, delete: delete));
  }
  final _ProjectResources res;
  try {
    res = getResources(projectDir);
  } on MetaMismatchError catch (e) {
    return textResult('Error: ${e.message}');
  }

  try {
    switch (operation) {
      case 'scan':
        return ScanOperations(
          database: res.database,
          workingDir: workingDir,
          dbPath: res.dbPath,
          allowedPaths: allowedPaths,
          onDatabaseReplaced: (newDb) => res.database = newDb,
        ).scan(args);
      case 'index-files':
        return await WriteOperations(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
          extractor: res.extractor,
        ).indexFiles(args);
      case 'get-file':
        return BrowseOperations(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
          dbPath: res.dbPath,
        ).getFile(args);
      case 'get-files':
        return BrowseOperations(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
          dbPath: res.dbPath,
        ).getFiles(args);
      case 'overview':
        return BrowseOperations(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
          dbPath: res.dbPath,
        ).overview(args);
      case 'project-info':
        return BrowseOperations(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
          dbPath: res.dbPath,
        ).projectInfo(args);
      case 'search':
        return SearchOperations(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
        ).search(args);
      case 'stats':
        return SearchOperations(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
        ).stats(args);
      case 'find-symbol':
        return SymbolQueries(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
        ).findSymbol(args);
      case 'references':
        return SymbolQueries(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
        ).references(args);
      case 'dependents':
        return GraphQueries(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
        ).dependents(args);
      case 'dependencies':
        return GraphQueries(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
        ).dependencies(args);
      case 'annotations':
        return GraphQueries(
          database: res.database,
          workingDir: workingDir,
          allowedPaths: allowedPaths,
        ).annotations(args);
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
      logWarning(
        'code-index',
        'CRITICAL: Database corruption detected. Database may need repair.',
      );
    }

    return textResult('Error: $userMessage');
  } catch (e, stackTrace) {
    return errorResult('code-index:$operation', e, stackTrace, {
      'operation': operation,
    });
  }
}

void _printUsage() {
  stderr.writeln(
    'Usage: code_index_mcp --project-dir=PATH1 [--project-dir=PATH2 ...] [--data-root=PATH]',
  );
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln(
    '  --project-dir=PATH   Path to a project directory (required, can be repeated)',
  );
  stderr.writeln(
    '  --data-root=PATH     Root of the code-index store (optional, default ~/.code-index)',
  );
  stderr.writeln('  --help, -h           Show this help message');
  stderr.writeln('');
  stderr.writeln('Operations:');
  stderr.writeln(
    '  scan           Walk the tree, detect changes, return an indexing plan',
  );
  stderr.writeln('  index-files    Batched write of file records (1..N)');
  stderr.writeln('  get-file       Get a single file with layered data');
  stderr.writeln('  get-files      Get multiple files with layered data');
  stderr.writeln(
    '  overview       Compact listing: path, summary, tags, public symbols',
  );
  stderr.writeln('  search         FTS5 search across the index');
  stderr.writeln('  find-symbol    Resolve a declaration to file + line range');
  stderr.writeln(
    '  references     Which files use a symbol (dot-path queries)',
  );
  stderr.writeln('  dependents     Which files import a given path');
  stderr.writeln('  dependencies   What a file imports (internal/external)');
  stderr.writeln('  annotations    TODO/FIXME/HACK/NOTE/DEPRECATED queries');
  stderr.writeln('  stats          Aggregate statistics about the code index');
  stderr.writeln(
    '  project-info   Data dir, db path, registry entry, schema version',
  );
  stderr.writeln(
    '  is-allowed     Check if a path is within the allowed paths',
  );
  stderr.writeln(
    '  prune-stores   Report/remove orphaned stores under the data root',
  );
  stderr.writeln('');
  stderr.writeln(
    'The store lives at [data-root]/[basename]-[sha8] (default ~/.code-index).',
  );
  stderr.writeln(
    "Git worktrees (<root>/.worktrees/<slug>) share their main checkout's store.",
  );
  stderr.writeln(
    'Allowed paths are resolved from jhsware_code.yaml (or legacy jhsware-code.yaml) in each project directory.',
  );
}
