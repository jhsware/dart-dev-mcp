import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:planner_mcp/planner_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Planner MCP Server
///
/// Provides task and step management for AI-assisted development workflows.
/// Stores data in a SQLite database in the project's .ai_coding_tool folder.
///
/// Usage: `dart run bin/planner_mcp.dart --project-dir=PATH`
void main(List<String> arguments) async {
  String? projectDir;
  String? dbPath;

  // Parse arguments
  for (final arg in arguments) {
    if (arg.startsWith('--project-dir=')) {
      projectDir = arg.substring('--project-dir='.length);
    } else if (arg.startsWith('--db-path=')) {
      dbPath = arg.substring('--db-path='.length);
    } else if (arg == '--help' || arg == '-h') {
      _printUsage();
      exit(0);
    }
  }

  // Validate required arguments
  if (projectDir == null || projectDir.isEmpty) {
    stderr.writeln('Error: --project-dir is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }
  
  if (dbPath == null || dbPath.isEmpty) {
    stderr.writeln('Error: --db-path is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  final workingDir = Directory(p.normalize(p.absolute(projectDir)));

  if (!await workingDir.exists()) {
    stderr.writeln('Error: Project path does not exist: $projectDir');
    exit(1);
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

  // Create operation handlers
  final taskOps = TaskOperations(
    database: database,
    transactionLogRepository: transactionLogRepository,
  );
  final stepOps = StepOperations(
    database: database,
    transactionLogRepository: transactionLogRepository,
  );
  final timelineOps = TimelineOperations(
    transactionLogRepository: transactionLogRepository,
  );

  logInfo('planner', 'Planner MCP Server starting...');
  logInfo('planner', 'Project path: ${workingDir.path}');
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
  server.tool(
    'planner',
    description: '''Task and step management for AI-assisted development.

Operations:
- get-project-instructions: Read project instructions from .ai_coding_tool/INSTRUCTIONS.md
- add-task: Create a new task
- show-task: Show task details with list of steps
- update-task: Update task properties
- show-task-memory: Show task memory/notes
- update-task-memory: Update task memory/notes
- list-tasks: List all tasks (optional filters: project_id, status)
- add-step: Add a step to a task
- show-step: Show step details
- update-step: Update step properties
- get-timeline: Get recent activity timeline (optional: limit, project_id, entity_type, before, after)
- get-audit-trail: Get detailed change history for an entity (requires: entity_type, id)

Task statuses: backlog, todo, draft, started, canceled, done, merged
Step statuses: todo, started, canceled, done''',
    toolInputSchema: ToolInputSchema(
      properties: {
        'operation': {
          'type': 'string',
          'description': 'The operation to perform',
          'enum': _validOperations,
        },
        'id': {
          'type': 'string',
          'description':
              'Task or step ID (for show/update/audit-trail operations)',
        },
        'task_id': {
          'type': 'string',
          'description': 'Parent task ID (for add-step)',
        },
        'project_id': {
          'type': 'string',
          'description':
              'Project identifier (for add-task, list-tasks filter, timeline filter)',
        },
        'title': {
          'type': 'string',
          'description': 'Title for task or step',
        },
        'details': {
          'type': 'string',
          'description': 'Detailed description for task or step',
        },
        'status': {
          'type': 'string',
          'description':
              'Status for tasks: backlog, todo, draft, started, canceled, done, merged. Status for steps: todo, started, canceled, done. Also used for list-tasks filter.',
          'enum': [
            'backlog',
            'todo',
            'draft',
            'started',
            'canceled',
            'done',
            'merged'
          ],
        },
        'memory': {
          'type': 'string',
          'description': 'Memory/notes content for task',
        },
        'entity_type': {
          'type': 'string',
          'description':
              "Entity type filter: 'task' or 'step' (for timeline/audit-trail)",
          'enum': ['task', 'step'],
        },
        'limit': {
          'type': 'integer',
          'description':
              'Maximum entries to return (for get-timeline, default 20)',
        },
        'before': {
          'type': 'string',
          'description':
              'Return entries before this ISO datetime (for get-timeline)',
        },
        'after': {
          'type': 'string',
          'description':
              'Return entries after this ISO datetime (for get-timeline)',
        },
      },
    ),
    callback: ({args, extra}) => _handlePlanner(
        args, workingDir, database, taskOps, stepOps, timelineOps),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('planner', 'Planner MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln('Usage: planner_mcp --project-dir=PATH');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln(
      '  --project-dir=PATH  Path to the project directory (required)');
  stderr.writeln('  --help, -h          Show this help message');
  stderr.writeln('');
  stderr.writeln('The planner stores data in .ai_coding_tool/db.sqlite');
  stderr.writeln(
      'Project instructions are read from .ai_coding_tool/INSTRUCTIONS.md');
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
  'get-timeline',
  'get-audit-trail',
];

Future<CallToolResult> _handlePlanner(
  Map<String, dynamic>? args,
  Directory workingDir,
  Database database,
  TaskOperations taskOps,
  StepOperations stepOps,
  TimelineOperations timelineOps,
) async {
  final operation = args?['operation'] as String?;

  if (requireStringOneOf(operation, 'operation', _validOperations)
      case final error?) {
    return error;
  }

  try {
    switch (operation) {
      case 'get-project-instructions':
        return _getProjectInstructions(workingDir);
      case 'add-task':
        return taskOps.addTask(args);
      case 'show-task':
        return taskOps.showTask(args);
      case 'update-task':
        return taskOps.updateTask(args);
      case 'show-task-memory':
        return taskOps.showTaskMemory(args);
      case 'update-task-memory':
        return taskOps.updateTaskMemory(args);
      case 'list-tasks':
        return taskOps.listTasks(args);
      case 'add-step':
        return stepOps.addStep(args);
      case 'show-step':
        return stepOps.showStep(args);
      case 'update-step':
        return stepOps.updateStep(args);
      case 'get-timeline':
        return timelineOps.getTimeline(args);
      case 'get-audit-trail':
        return timelineOps.getAuditTrail(args);
      default:
        return validationError('operation', 'Unknown operation: $operation');
    }
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
      p.join(workingDir.path, '.ai_coding_tool', 'INSTRUCTIONS.md');
  final file = File(instructionsPath);

  if (!await file.exists()) {
    return textResult('No project instructions found.\n'
        'Create a file at: .ai_coding_tool/INSTRUCTIONS.md');
  }

  final content = await file.readAsString();
  return textResult(content);
}
