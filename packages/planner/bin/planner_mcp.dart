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
/// Stores data in a SQLite database inferred from --planner-data-root.
///
/// Usage: `dart run bin/planner_mcp.dart --planner-data-root=PATH --project-dir=PATH1 [--project-dir=PATH2 ...]`
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

  if (serverArgs.plannerDataRoot == null) {
    stderr.writeln('Error: --planner-data-root is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  // Validate all project directories exist
  for (final dir in serverArgs.projectDirs) {
    final workingDir = Directory(dir);
    if (!await workingDir.exists()) {
      stderr.writeln('Error: Project path does not exist: $dir');
      exit(1);
    }
  }

  // Initialize prompt pack service
  final promptPackService = PromptPackService(
    promptsFilePath: serverArgs.promptsFilePath,
  );
  promptPackService.initialize();

  // Per-project database connections (created on demand)
  final databases = <String, Database>{};

  /// Get or create database connection for a project directory.
  Database getDatabase(String projectDir) {
    if (databases.containsKey(projectDir)) {
      return databases[projectDir]!;
    }
    final dbPath = serverArgs.plannerDbPath(projectDir);
    // Ensure parent directory exists
    final dbDir = Directory(p.dirname(dbPath));
    if (!dbDir.existsSync()) {
      dbDir.createSync(recursive: true);
    }
    final db = initializeDatabase(dbPath);
    // Initialize transaction log table for this DB
    final txRepo = TransactionLogRepository(db);
    txRepo.initializeTable();
    databases[projectDir] = db;
    return db;
  }

  logInfo('planner', 'Planner MCP Server starting...');
  logInfo('planner',
      'Project dirs: ${serverArgs.projectDirs.join(", ")}');
  logInfo('planner',
      'Planner data root: ${serverArgs.plannerDataRoot}');

  // Set up graceful shutdown to close all databases
  ProcessSignal.sigint.watch().listen((_) {
    for (final db in databases.values) {
      db.dispose();
    }
    exit(0);
  });

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
- list-projects: List all registered project directories with their short names. Returns project_dir (full path) and project_name (basename) for each. Does not require a specific project_dir context.
- get-project-instructions: Read project instructions from AGENTS.md
- get-project-instructions: Read project instructions from AGENTS.md
- add-task: Create a new task
- show-task: Show task details with list of steps and linked backlog items. Requires: id.
- update-task: Update task properties
- show-task-memory: Show task memory/notes
- update-task-memory: Update task memory/notes
- list-tasks: List all tasks (optional filter: status). Supports pagination: start_at (default 0), limit (default 30, max 100).
- add-step: Add a step to a task. Use sub_task_id to link the step to a sub-task (for parent task pattern).
- show-step: Show step details
- update-step: Update step properties
- get-subtask-prompt: Get the sub-task details for a step in a parent task. Use this operation to fetch the sub-task details when ready to work on it. Requires: id (step ID). Returns error if step has no linked sub-task.
- add-item: Create a new backlog item. Requires: title. Optional: details, type, status.
- show-item: Show item details with edit history, linked tasks, and linked slates. Requires: id.
- update-item: Update item fields. Requires: id. Optional: title, details, type, status.
- list-items: List items with filters. Optional: search_query, type, status, backlog_only (boolean, returns only items not in any slate). Supports pagination: start_at (default 0), limit (default 30, max 100).
- add-slate: Create a new slate. Requires: title. Optional: notes, status (draft/todo/started/done/released, default draft), release_date (ISO 8601 date).
- show-slate: Show slate with its items (includes status and release_date). Requires: id.
- update-slate: Update slate fields. Requires: id. Optional: title, notes, status, release_date.
- list-slates: List all slates. Optional: status filter. Supports pagination: start_at (default 0), limit (default 30, max 100).
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
Item types: feature, improvement, bug, change, investigation
Item statuses: open, closed, archived
Slate statuses: draft, todo, started, done, released

Parent task pattern: Prefix parent task title with "Parent:". Each step references a sub-task via sub_task_id. Use get-subtask-prompt to fetch the sub-task details for a step when ready to work on it.''',
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
        'id': JsonSchema.string(
          description:
              'Task or step ID (for show/update/audit-trail operations)',
        ),
        'task_id': JsonSchema.string(
          description: 'Parent task ID (for add-step, log-commit, log-merge)',
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
              'Maximum entries to return. Defaults: list-tasks/list-items/list-slates = 30 (max 100), get-timeline = 20.',
        ),
        'start_at': JsonSchema.integer(
          description:
              'Zero-based offset into the result set for list-tasks, list-items, list-slates. Default 0.',
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
          description:
              'Step ID associated with a git commit (for log-commit, optional)',
        ),
        'type': JsonSchema.string(
          description: 'Item type: feature, improvement, bug, change, investigation',
          enumValues: ['feature', 'improvement', 'bug', 'change', 'investigation'],
        ),
        'notes': JsonSchema.string(
          description: 'Slate notes (markdown)',
        ),
        'search_query': JsonSchema.string(
          description:
              'Search query for filtering items by title and details',
        ),
        'release_id': JsonSchema.string(
          description: 'Slate ID (for add/remove-item-to/from-slate)',
        ),
        'item_id': JsonSchema.string(
          description:
              'Item ID (for add/remove-item-to/from-slate, add/remove-item-to/from-task)',
        ),
        'release_date': JsonSchema.string(
          description:
              'Target slate date in ISO 8601 format (for add-slate, update-slate)',
        ),
        'backlog_only': JsonSchema.boolean(
          description:
              'When true, list-items returns only items not assigned to any slate',
        ),
      },
      required: ['project_dir'],
    ),
    callback: (args, extra) => _handlePlanner(
        args, serverArgs, getDatabase, promptPackService),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('planner', 'Planner MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln(
      'Usage: planner_mcp --planner-data-root=PATH --project-dir=PATH1 [--project-dir=PATH2 ...]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln(
      '  --project-dir=PATH        Path to a project directory (required, can be repeated)');
  stderr.writeln(
      '  --planner-data-root=PATH  Root directory for planner data (required)');
  stderr.writeln(
      '  --prompts-file=PATH       Path to prompts YAML file (optional, uses defaults)');
  stderr.writeln('  --help, -h                Show this help message');
  stderr.writeln('');
  stderr.writeln(
      'DB paths are inferred as: [planner-data-root]/projects/[project-dir-name]/db/planner.db');
  stderr.writeln(
      'Project instructions are read from AGENTS.md in each project directory.');
}

const _validOperations = [
  'list-projects',
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

Future<CallToolResult> _handlePlanner(
  Map<String, dynamic> args,
  ServerArguments serverArgs,
  Database Function(String projectDir) getDatabase,
  PromptPackService promptPackService,
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
  if (requireStringOneOf(operation, 'operation', _validOperations)
      case final error?) {
    return error;
  }

  // Handle list-projects before DB setup (it's a global operation)
  if (operation == 'list-projects') {
    final projects = serverArgs.projectDirs.map((dir) => {
      'project_dir': dir,
      'project_name': p.basename(dir),
    }).toList();
    return jsonResult({'projects': projects, 'count': projects.length});
  }

  // Get or create database for this project
  final database = getDatabase(projectDir!);
  final transactionLogRepository = TransactionLogRepository(database);

  // Create operation handlers for this project's database
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

  final workingDir = Directory(projectDir);

  try {
    final CallToolResult result;
    switch (operation) {
      case 'get-project-instructions':
        return _getProjectInstructions(workingDir, projectDir);
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
        return _injectProjectDirText(
            stepOps.getSubtaskPrompt(args), projectDir);
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
    // Inject project_dir into JSON responses
    return _injectProjectDirJson(result, projectDir);
  } on SqliteException catch (e) {
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

Future<CallToolResult> _getProjectInstructions(
    Directory workingDir, String projectDir) async {
  final instructionsPath = p.join(workingDir.path, 'AGENTS.md');
  final file = File(instructionsPath);

  if (!await file.exists()) {
    return textResult('Project dir: $projectDir\n\n'
        'No project instructions found.\n'
        'Create a file at: AGENTS.md');
  }

  final content = await file.readAsString();
  return textResult('Project dir: $projectDir\n\n$content');
}

/// Injects project_dir into a JSON response.
///
/// Parses the text content as JSON, adds project_dir at the top level,
/// and re-serializes. If the text starts with "Error:", it's returned as-is.
CallToolResult _injectProjectDirJson(
    CallToolResult result, String projectDir) {
  if (result.content.isEmpty) return result;
  final content = result.content.first;
  if (content is! TextContent) return result;
  final text = content.text;
  // Don't inject into error responses
  if (text.startsWith('Error:')) return result;
  try {
    final data = jsonDecode(text) as Map<String, dynamic>;
    final augmented = {'project_dir': projectDir, ...data};
    return jsonResult(augmented);
  } catch (_) {
    // If not valid JSON, treat as text and prepend project_dir
    return textResult('Project dir: $projectDir\n\n$text');
  }
}

/// Injects project_dir into a text response.
///
/// Prepends "Project dir: <projectDir>" to the text content.
/// If the text starts with "Error:", it's returned as-is.
CallToolResult _injectProjectDirText(
    CallToolResult result, String projectDir) {
  if (result.content.isEmpty) return result;
  final content = result.content.first;
  if (content is! TextContent) return result;
  final text = content.text;
  // Don't inject into error responses
  if (text.startsWith('Error:')) return result;
  return textResult('Project dir: $projectDir\n\n$text');
}
