import 'dart:convert';
import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:planner_mcp/planner_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Planner MCP Server
///
/// Provides task and step management for AI-assisted development workflows.
/// Stores data in a SQLite database.
///
/// Usage: `dart run bin/planner_mcp.dart --db-path=PATH [--project-dir=PATH]`
///
/// When project_root is passed as a tool call parameter, it overrides
/// the CLI --project-dir and is included in all JSON responses.
void main(List<String> arguments) async {
  String? projectDir;
  String? dbPath;
  String? promptsFilePath;

  // Parse arguments
  for (final arg in arguments) {
    if (arg.startsWith('--project-dir=')) {
      projectDir = arg.substring('--project-dir='.length);
    } else if (arg.startsWith('--db-path=')) {
      dbPath = arg.substring('--db-path='.length);
    } else if (arg.startsWith('--prompts-file=')) {
      promptsFilePath = arg.substring('--prompts-file='.length);
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

  // CLI-provided default (used as fallback when project_root not in tool call)
  Directory? cliWorkingDir;

  if (projectDir != null && projectDir.isNotEmpty) {
    cliWorkingDir = Directory(p.normalize(p.absolute(projectDir)));

    if (!await cliWorkingDir.exists()) {
      stderr.writeln('Error: Project path does not exist: $projectDir');
      exit(1);
    }
  }

  // Ensure parent directory of database file exists
  if (dbPath != ':memory:') {
    final dbDir = Directory(p.dirname(dbPath));
    if (!await dbDir.exists()) {
      await dbDir.create(recursive: true);
    }
  }

  // Initialize database
  final database = initializeDatabase(dbPath);

  // Initialize transaction log repository
  final transactionLogRepository = TransactionLogRepository(database);
  transactionLogRepository.initializeTable();

  // Initialize prompt pack service
  final promptPackService = PromptPackService(
    promptsFilePath: promptsFilePath,
  );
  promptPackService.initialize();

  // Create operation handlers
  final taskOps = TaskOperations(
    database: database,
    transactionLogRepository: transactionLogRepository,
  );
  final stepOps = StepOperations(
    database: database,
    transactionLogRepository: transactionLogRepository,
    promptPackService: promptPackService,
  );
  final timelineOps = TimelineOperations(
    transactionLogRepository: transactionLogRepository,
  );
  final gitLogOps = GitLogOperations(
    database: database,
    transactionLogRepository: transactionLogRepository,
  );
  final itemOps = ItemOperations(
    database: database,
    transactionLogRepository: transactionLogRepository,
  );
  final slateOps = SlateOperations(
    database: database,
    transactionLogRepository: transactionLogRepository,
  );

  logInfo('planner', 'Planner MCP Server starting...');
  if (cliWorkingDir != null) {
    logInfo('planner', 'CLI project path: ${cliWorkingDir.path}');
  } else {
    logInfo('planner', 'No CLI project directory set, project_root param required in tool calls');
  }
  logInfo('planner', 'Database: $dbPath');

  // Set up graceful shutdown to close database
  setupShutdownHandlers(database);

  final server = McpServer(
    Implementation(name: 'planner-mcp', version: '1.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the planner tool
  server.registerTool(
    'planner',
    description: '''Task and step management for AI-assisted development.

Operations:
- get-project-instructions: Read project instructions from AGENTS.md
- add-task: Create a new task
- show-task: Show task details with list of steps and linked backlog items. Requires: id.
- update-task: Update task properties
- show-task-memory: Show task memory/notes
- update-task-memory: Update task memory/notes
- list-tasks: List all tasks (optional filter: status)
- add-step: Add a step to a task. Use sub_task_id to link the step to a sub-task (for parent task pattern).
- show-step: Show step details
- update-step: Update step properties
- get-subtask-prompt: Get the sub-task details for a step in a parent task. Use this operation to fetch the sub-task details when ready to work on it. Requires: id (step ID). Returns error if step has no linked sub-task.
- add-item: Create a new backlog item. Requires: title. Optional: details, type, status, project_id (deprecated).
- show-item: Show item details with edit history, linked tasks, and linked slates. Requires: id.
- update-item: Update item fields. Requires: id. Optional: title, details, type, status.
- list-items: List items with filters. Optional: search_query, type, status, backlog_only (boolean, returns only items not in any slate).
- add-slate: Create a new slate. Requires: title. Optional: notes, status (draft/todo/started/done/released, default draft), release_date (ISO 8601 date), project_id (deprecated).
- show-slate: Show slate with its items (includes status and release_date). Requires: id.
- update-slate: Update slate fields. Requires: id. Optional: title, notes, status, release_date.
- list-slates: List all slates. Optional: status filter.
- add-item-to-slate: Assign item to slate. Requires: release_id, item_id.
- remove-item-from-slate: Remove item from slate. Requires: release_id, item_id.
- add-item-to-task: Link a backlog item to a task. Requires: task_id, item_id.
- remove-item-from-task: Unlink a backlog item from a task. Requires: task_id, item_id.
- log-commit: Log a git commit to the timeline. Records commits so they appear in the timeline viewer alongside task activity. Requires: commit_hash, branch, task_id. Optional: step_id, message.
- log-merge: Log a git branch merge to the timeline. Records merges so they appear in the timeline viewer. Requires: commit_hash, source_branch, target_branch, task_id.
- get-timeline: Get recent activity timeline (optional: limit, entity_type, before, after)
- get-audit-trail: Get detailed change history for an entity (requires: entity_type, id)

Task statuses: backlog, todo, draft, started, canceled, done, merged
Step statuses: todo, started, canceled, done
Item types: feature, improvement, bug, change
Item statuses: open, closed, archived
Slate statuses: draft, todo, started, done, released

Parent task pattern: Prefix parent task title with "Parent:". Each step references a sub-task via sub_task_id. Use get-subtask-prompt to fetch the sub-task details for a step when ready to work on it.''',
    inputSchema: ToolInputSchema(
      properties: {
        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: _validOperations,
        ),
        'id': JsonSchema.string(
          description:
              'Task or step ID (for show/update/audit-trail operations)',
        ),
        'task_id': JsonSchema.string(
          description: 'Parent task ID (for add-step, log-commit, log-merge)',
        ),
        'project_id': JsonSchema.string(
          description:
              'DEPRECATED: No longer used for filtering. Kept for backward compatibility. Defaults to empty string if not provided.',
        ),
        'title': JsonSchema.string(
          description: 'Title for task or step',
        ),
        'details': JsonSchema.string(
          description: 'Detailed description for task or step',
        ),
        'sub_task_id': JsonSchema.string(
          description:
              'Optional reference to another task ID (sub-task). Used when creating parent tasks whose steps reference sub-tasks. Use get-subtask-prompt to fetch the sub-task details.',
        ),
        'status': JsonSchema.string(
          description:
              'Status for tasks: backlog, todo, draft, started, canceled, done, merged. Status for steps: todo, started, canceled, done. Status for items: open, closed, archived. Status for slates: draft, todo, started, done, released. Also used for list-tasks and list-slates filter.',
          enumValues: [
            'backlog',
            'todo',
            'draft',
            'started',
            'canceled',
            'done',
            'merged',
            'open',
            'closed',
            'archived',
            'released'
          ],
        ),
        'memory': JsonSchema.string(
          description: 'Memory/notes content for task',
        ),
        'entity_type': JsonSchema.string(
          description:
              "Entity type filter: 'task', 'step', 'item', or 'slate' (for timeline/audit-trail)",
          enumValues: ['task', 'step', 'item', 'slate'],
        ),
        'limit': JsonSchema.integer(
          description:
              'Maximum entries to return (for get-timeline, default 20)',
        ),
        'before': JsonSchema.string(
          description:
              'Return entries before this ISO datetime (for get-timeline)',
        ),
        'after': JsonSchema.string(
          description:
              'Return entries after this ISO datetime (for get-timeline)',
        ),
        'commit_hash': JsonSchema.string(
          description: 'Git commit hash (for log-commit, log-merge)',
        ),
        'branch': JsonSchema.string(
          description: 'Git branch name (for log-commit)',
        ),
        'source_branch': JsonSchema.string(
          description: 'Source branch name being merged (for log-merge)',
        ),
        'target_branch': JsonSchema.string(
          description: 'Target branch name being merged into (for log-merge)',
        ),
        'message': JsonSchema.string(
          description: 'Commit message (for log-commit, optional)',
        ),
        'step_id': JsonSchema.string(
          description: 'Step ID associated with a git commit (for log-commit, optional)',
        ),
        'type': JsonSchema.string(
          description: 'Item type: feature, improvement, bug, change',
          enumValues: ['feature', 'improvement', 'bug', 'change'],
        ),
        'notes': JsonSchema.string(
          description: 'Slate notes (markdown)',
        ),
        'search_query': JsonSchema.string(
          description: 'Search query for filtering items by title and details',
        ),
        'release_id': JsonSchema.string(
          description: 'Slate ID (for add/remove-item-to/from-slate)',
        ),
        'item_id': JsonSchema.string(
          description: 'Item ID (for add/remove-item-to/from-slate, add/remove-item-to/from-task)',
        ),
        'release_date': JsonSchema.string(
          description: 'Target slate date in ISO 8601 format (for add-slate, update-slate)',
        ),
        'backlog_only': JsonSchema.boolean(
          description: 'When true, list-items returns only items not assigned to any slate',
        ),
      },
    ),
    callback: (args, extra) => _handlePlanner(
        args, cliWorkingDir, database, taskOps, stepOps, timelineOps, gitLogOps, itemOps, slateOps),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('planner', 'Planner MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln('Usage: planner_mcp --db-path=PATH [--project-dir=PATH]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln(
      '  --project-dir=PATH    Path to the project directory (fallback)');
  stderr.writeln(
      '  --db-path=PATH        Path to the SQLite database file (required)');
  stderr.writeln(
      '  --prompts-file=PATH   Path to prompts YAML file (optional, uses defaults)');
  stderr.writeln('  --help, -h            Show this help message');
  stderr.writeln('');
  stderr.writeln('Note: When project_root is provided in a tool call, it overrides --project-dir');
  stderr.writeln('and is included in all JSON responses.');
}

const _validOperations = [
  'get-project-instructions',
  'add-task',
  'show-task',
  'update-task',
  'show-task-memory',
  'update-task-memory',
  'list-tasks',
  'add-step',
  'show-step',
  'update-step',
  'get-subtask-prompt',
  'add-item',
  'show-item',
  'update-item',
  'list-items',
  'add-slate',
  'show-slate',
  'update-slate',
  'list-slates',
  'add-item-to-slate',
  'remove-item-from-slate',
  'add-item-to-task',
  'remove-item-from-task',
  'log-commit',
  'log-merge',
  'get-timeline',
  'get-audit-trail',
];

/// Resolve workingDir from project_root parameter or CLI fallback.
Directory? _resolveWorkingDir(
  Map<String, dynamic> args,
  Directory? cliWorkingDir,
) {
  final projectRoot = args['project_root'] as String?;

  if (projectRoot != null && projectRoot.isNotEmpty) {
    return Directory(p.normalize(p.absolute(projectRoot)));
  }

  return cliWorkingDir;
}

/// Inject project_root into a CallToolResult's JSON text content.
///
/// If the result contains JSON text, parses it, adds `project_root` at the
/// top level (for maps) or wraps in an envelope (for lists), and re-serializes.
/// Non-JSON text results are returned as-is.
CallToolResult _injectProjectRoot(CallToolResult result, String projectRoot) {
  if (result.content.isEmpty) return result;

  final firstContent = result.content.first;
  if (firstContent is! TextContent) return result;

  final text = firstContent.text;

  // Try to parse as JSON
  try {
    final decoded = jsonDecode(text);

    if (decoded is Map<String, dynamic>) {
      decoded['project_root'] = projectRoot;
      return textResult(jsonEncode(decoded));
    } else if (decoded is List) {
      // Wrap list in envelope with project_root
      final envelope = {
        'project_root': projectRoot,
        'data': decoded,
      };
      return textResult(jsonEncode(envelope));
    }
  } catch (_) {
    // Not JSON — return as-is
  }

  return result;
}

Future<CallToolResult> _handlePlanner(
  Map<String, dynamic> args,
  Directory? cliWorkingDir,
  Database database,
  TaskOperations taskOps,
  StepOperations stepOps,
  TimelineOperations timelineOps,
  GitLogOperations gitLogOps,
  ItemOperations itemOps,
  SlateOperations slateOps,
) async {
  final operation = args['operation'] as String?;

  if (requireStringOneOf(operation, 'operation', _validOperations)
      case final error?) {
    return error;
  }

  // Resolve working directory
  final workingDir = _resolveWorkingDir(args, cliWorkingDir);
  final projectRoot = workingDir?.path;

  try {
    CallToolResult result;

    switch (operation) {
      case 'get-project-instructions':
        if (workingDir == null) {
          return validationError('project_root',
              'No project_root provided and no CLI --project-dir configured. '
              'Either pass project_root in the tool call or start the server with --project-dir.');
        }
        result = await _getProjectInstructions(workingDir);
      case 'add-task':
        result = taskOps.addTask(args);
      case 'show-task':
        result = taskOps.showTask(args);
      case 'update-task':
        result = taskOps.updateTask(args);
      case 'show-task-memory':
        result = taskOps.showTaskMemory(args);
      case 'update-task-memory':
        result = taskOps.updateTaskMemory(args);
      case 'list-tasks':
        result = taskOps.listTasks(args);
      case 'add-step':
        result = stepOps.addStep(args);
      case 'show-step':
        result = stepOps.showStep(args);
      case 'update-step':
        result = stepOps.updateStep(args);
      case 'get-subtask-prompt':
        result = stepOps.getSubtaskPrompt(args);
      case 'add-item':
        result = itemOps.addItem(args);
      case 'show-item':
        result = itemOps.showItem(args);
      case 'update-item':
        result = itemOps.updateItem(args);
      case 'list-items':
        result = itemOps.listItems(args);
      case 'add-slate':
        result = slateOps.addSlate(args);
      case 'show-slate':
        result = slateOps.showSlate(args);
      case 'update-slate':
        result = slateOps.updateSlate(args);
      case 'list-slates':
        result = slateOps.listSlates(args);
      case 'add-item-to-slate':
        result = slateOps.addItemToSlate(args);
      case 'remove-item-from-slate':
        result = slateOps.removeItemFromSlate(args);
      case 'add-item-to-task':
        result = slateOps.addItemToTask(args);
      case 'remove-item-from-task':
        result = slateOps.removeItemFromTask(args);
      case 'log-commit':
        result = gitLogOps.logCommit(args);
      case 'log-merge':
        result = gitLogOps.logMerge(args);
      case 'get-timeline':
        result = timelineOps.getTimeline(args);
      case 'get-audit-trail':
        result = timelineOps.getAuditTrail(args);
      default:
        return validationError('operation', 'Unknown operation: $operation');
    }

    // Inject project_root into JSON responses
    if (projectRoot != null) {
      return _injectProjectRoot(result, projectRoot);
    }

    return result;
  } on SqliteException catch (e) {
    // Classify the error for appropriate handling
    final category = classifyError(e);
    final userMessage = userFriendlyMessage(category, e.message);

    logError('planner:$operation', e, null, {
      'category': category.toString(),
      'resultCode': e.resultCode,
      'extendedResultCode': e.extendedResultCode,
    });

    if (category == SqliteErrorCategory.corruption) {
      logWarning('planner',
          'CRITICAL: Database corruption detected. Database may need repair.');
    }

    return textResult('Error: $userMessage');
  } catch (e, stackTrace) {
    return errorResult('planner:$operation', e, stackTrace, {
      'operation': operation,
    });
  }
}

Future<CallToolResult> _getProjectInstructions(Directory workingDir) async {
  final instructionsPath =
      p.join(workingDir.path, 'AGENTS.md');
  final file = File(instructionsPath);

  if (!await file.exists()) {
    return textResult('No project instructions found.\n'
        'Create a file at: AGENTS.md');
  }

  final content = await file.readAsString();
  return textResult(content);
}
