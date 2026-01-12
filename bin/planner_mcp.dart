import 'dart:io';

import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:dart_dev_mcp/mcp_server/utils/sqlite_helpers.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'package:dart_dev_mcp/planner/planner.dart';




/// Planner MCP Server
///
/// Provides task and step management for AI-assisted development workflows.
/// Stores data in a SQLite database in the project's .ai_coding_tool folder.
///
/// Usage: `dart run bin/planner_mcp.dart --project-dir=PATH`
void main(List<String> arguments) async {
  String? projectDir;

  // Parse arguments
  for (final arg in arguments) {
    if (arg.startsWith('--project-dir=')) {
      projectDir = arg.substring('--project-dir='.length);
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

  final workingDir = Directory(p.normalize(p.absolute(projectDir)));

  if (!await workingDir.exists()) {
    stderr.writeln('Error: Project path does not exist: $projectDir');
    exit(1);
  }

  // Create .ai_coding_tool directory if it doesn't exist
  final aiToolDir = Directory(p.join(workingDir.path, '.ai_coding_tool'));
  if (!await aiToolDir.exists()) {
    await aiToolDir.create(recursive: true);
  }

  // Initialize database
  final dbPath = p.join(aiToolDir.path, 'db.sqlite');
  final database = _initializeDatabase(dbPath);
  
  // Initialize transaction log repository
  final transactionLogRepository = TransactionLogRepository(database);
  transactionLogRepository.initializeTable();

  logInfo('planner', 'Planner MCP Server starting...');
  logInfo('planner', 'Project path: ${workingDir.path}');
  logInfo('planner', 'Database: $dbPath');


  // Set up graceful shutdown to close database
  _setupShutdownHandlers(database);

  final server = McpServer(
    Implementation(name: 'planner-mcp', version: '1.0.0'),
    options: ServerOptions(
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

Task statuses: todo, draft, started, canceled, done, merged
Step statuses: todo, started, canceled, done''',
    toolInputSchema: ToolInputSchema(
      properties: {
        'operation': {
          'type': 'string',
          'description': 'The operation to perform',
          'enum': [
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
          ],
        },
        'id': {
          'type': 'string',
          'description': 'Task or step ID (for show/update/audit-trail operations)',
        },
        'task_id': {
          'type': 'string',
          'description': 'Parent task ID (for add-step)',
        },
        'project_id': {
          'type': 'string',
          'description': 'Project identifier (for add-task, list-tasks filter, timeline filter)',
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
              'Status for tasks: todo, draft, started, canceled, done, merged. Status for steps: todo, started, canceled, done. Also used for list-tasks filter.',
          'enum': ['todo', 'draft', 'started', 'canceled', 'done', 'merged'],
        },
        'memory': {
          'type': 'string',
          'description': 'Memory/notes content for task',
        },
        'entity_type': {
          'type': 'string',
          'description': "Entity type filter: 'task' or 'step' (for timeline/audit-trail)",
          'enum': ['task', 'step'],
        },
        'limit': {
          'type': 'integer',
          'description': 'Maximum entries to return (for get-timeline, default 20)',
        },
        'before': {
          'type': 'string',
          'description': 'Return entries before this ISO datetime (for get-timeline)',
        },
        'after': {
          'type': 'string',
          'description': 'Return entries after this ISO datetime (for get-timeline)',
        },
      },
    ),
    callback: ({args, extra}) => _handlePlanner(args, workingDir, database, transactionLogRepository),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('planner', 'Planner MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln('Usage: planner_mcp --project-dir=PATH');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln('  --project-dir=PATH  Path to the project directory (required)');
  stderr.writeln('  --help, -h          Show this help message');
  stderr.writeln('');
  stderr.writeln('The planner stores data in .ai_coding_tool/db.sqlite');
  stderr.writeln('Project instructions are read from .ai_coding_tool/INSTRUCTIONS.md');
}

/// Set up signal handlers for graceful shutdown
void _setupShutdownHandlers(Database database) {
  // Handle SIGINT (Ctrl+C)
  ProcessSignal.sigint.watch().listen((_) {
    logInfo('planner', 'Received SIGINT, closing database...');
    _closeDatabase(database);
    exit(0);
  });

  // Handle SIGTERM
  ProcessSignal.sigterm.watch().listen((_) {
    logInfo('planner', 'Received SIGTERM, closing database...');
    _closeDatabase(database);
    exit(0);
  });
}

/// Safely close the database
void _closeDatabase(Database database) {
  try {
    // Checkpoint WAL to main database before closing
    database.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    database.dispose();
    logInfo('planner', 'Database closed successfully');
  } catch (e, stackTrace) {
    logError('planner:close-database', e, stackTrace);
  }
}

// =============================================================================
// Database Initialization
// =============================================================================

/// Current schema version. Increment when making schema changes.
const int _currentSchemaVersion = 2;

Database _initializeDatabase(String dbPath) {
  final database = sqlite3.open(dbPath);
  
  // Enable WAL mode for better concurrent access and crash recovery
  // WAL mode is more resilient to corruption from unexpected shutdowns
  database.execute('PRAGMA journal_mode=WAL');
  
  // Set busy timeout to wait up to 5 seconds if database is locked
  database.execute('PRAGMA busy_timeout=5000');
  
  // Use NORMAL synchronous mode (good balance of safety and performance)
  // FULL is safer but slower, NORMAL is safe for WAL mode
  database.execute('PRAGMA synchronous=NORMAL');
  
  // Enable foreign key enforcement
  database.execute('PRAGMA foreign_keys=ON');
  
  // Create schema metadata table for version tracking
  database.execute('''
    CREATE TABLE IF NOT EXISTS schema_metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  
  // Create tasks table
  database.execute('''
    CREATE TABLE IF NOT EXISTS tasks (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      title TEXT NOT NULL,
      details TEXT,
      status TEXT NOT NULL DEFAULT 'todo',
      memory TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  
  // Create steps table
  database.execute('''
    CREATE TABLE IF NOT EXISTS steps (
      id TEXT PRIMARY KEY,
      task_id TEXT NOT NULL,
      title TEXT NOT NULL,
      details TEXT,
      status TEXT NOT NULL DEFAULT 'todo',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
    )
  ''');
  
  // Create indexes
  database.execute('CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON tasks(project_id)');
  database.execute('CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)');
  database.execute('CREATE INDEX IF NOT EXISTS idx_steps_task_id ON steps(task_id)');
  database.execute('CREATE INDEX IF NOT EXISTS idx_steps_status ON steps(status)');
  
  // Run migrations to ensure schema is up to date
  _runMigrations(database);
  
  return database;
}

/// Get the current schema version from the database.
/// Returns 0 if no version has been set (fresh database).
int _getSchemaVersion(Database database) {
  final result = database.select(
    "SELECT value FROM schema_metadata WHERE key = 'schema_version'"
  );
  if (result.isEmpty) {
    return 0;
  }
  return int.tryParse(result.first['value'] as String) ?? 0;
}

/// Set the schema version in the database.
void _setSchemaVersion(Database database, int version) {
  final now = DateTime.now().toUtc().toIso8601String();
  database.execute('''
    INSERT OR REPLACE INTO schema_metadata (key, value, updated_at)
    VALUES ('schema_version', ?, ?)
  ''', [version.toString(), now]);
}

/// Run all pending migrations to bring the schema up to date.
void _runMigrations(Database database) {
  final currentVersion = _getSchemaVersion(database);
  
  // Migration from version 0 (fresh) to version 1
  // This sets the initial version for existing databases
  if (currentVersion < 1) {
    logInfo('planner', 'Running migration to schema version 1...');
    // No schema changes needed - just establishing version tracking
    _setSchemaVersion(database, 1);
    logInfo('planner', 'Migration to schema version 1 complete.');
  }
  
  // Migration from version 1 to version 2
  // Add sort_order column for explicit step ordering
  if (currentVersion < 2) {
    logInfo('planner', 'Running migration to schema version 2...');
    // Add nullable sort_order column to steps table
    // Existing rows will have NULL, which will fall back to created_at ordering
    database.execute('ALTER TABLE steps ADD COLUMN sort_order INTEGER');
    _setSchemaVersion(database, 2);
    logInfo('planner', 'Migration to schema version 2 complete.');
  }
  
  // Future migrations will be added here:
  // if (currentVersion < 3) {
  //   // Run migration to v3
  //   _setSchemaVersion(database, 3);
  // }
  
  // Verify we're at the expected version
  final finalVersion = _getSchemaVersion(database);
  if (finalVersion != _currentSchemaVersion) {
    logWarning('planner', 'Schema version mismatch. Expected $_currentSchemaVersion, got $finalVersion');
  }
}


// =============================================================================
// Main Handler
// =============================================================================

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
  TransactionLogRepository transactionLogRepository,
) async {
  final operation = args?['operation'] as String?;

  if (requireStringOneOf(operation, 'operation', _validOperations) case final error?) {
    return error;
  }

  try {
    switch (operation) {
      case 'get-project-instructions':
        return _getProjectInstructions(workingDir);
      case 'add-task':
        return _addTask(database, args, transactionLogRepository);
      case 'show-task':
        return _showTask(database, args);
      case 'update-task':
        return _updateTask(database, args, transactionLogRepository);
      case 'show-task-memory':
        return _showTaskMemory(database, args);
      case 'update-task-memory':
        return _updateTaskMemory(database, args, transactionLogRepository);
      case 'list-tasks':
        return _listTasks(database, args);
      case 'add-step':
        return _addStep(database, args, transactionLogRepository);
      case 'show-step':
        return _showStep(database, args);
      case 'update-step':
        return _updateStep(database, args, transactionLogRepository);
      case 'get-timeline':
        return _getTimeline(args, transactionLogRepository);
      case 'get-audit-trail':
        return _getAuditTrail(args, transactionLogRepository);
      default:
        return validationError('operation', 'Unknown operation: $operation');
    }
  } on SqliteException catch (e) {
    // Classify the error for appropriate handling
    final category = classifyError(e);
    final userMessage = userFriendlyMessage(category, e.message);
    
    // Log with category for debugging
    logError('planner:$operation', e, null, {
      'category': category.toString(),
      'resultCode': e.resultCode,
      'extendedResultCode': e.extendedResultCode,
    });
    
    // For corruption errors, log a more urgent warning
    if (category == SqliteErrorCategory.corruption) {
      logWarning('planner', 'CRITICAL: Database corruption detected. Database may need repair.');
    }
    
    return textResult('Error: $userMessage');
  } catch (e, stackTrace) {
    return errorResult('planner:$operation', e, stackTrace, {
      'operation': operation,
    });
  }
}

// =============================================================================
// Project Instructions
// =============================================================================

Future<CallToolResult> _getProjectInstructions(Directory workingDir) async {
  final instructionsPath = p.join(workingDir.path, '.ai_coding_tool', 'INSTRUCTIONS.md');
  final file = File(instructionsPath);
  
  if (!await file.exists()) {
    return textResult(
      'No project instructions found.\n'
      'Create a file at: .ai_coding_tool/INSTRUCTIONS.md'
    );
  }
  
  final content = await file.readAsString();
  return textResult(content);
}

// =============================================================================
// Task Operations
// =============================================================================

final _uuid = Uuid();

const _validTaskStatuses = ['todo', 'draft', 'started', 'canceled', 'done', 'merged'];
const _validStepStatuses = ['todo', 'started', 'canceled', 'done'];

/// Normalizes legacy step statuses for backward compatibility.
/// - 'merged' → 'done'
/// - 'draft' → 'todo'
String _normalizeStepStatus(String status) {
  switch (status) {
    case 'merged':
      return 'done';
    case 'draft':
      return 'todo';
    default:
      return status;
  }
}

CallToolResult _addTask(Database database, Map<String, dynamic>? args, TransactionLogRepository transactionLogRepository) {
  final projectId = args?['project_id'] as String?;
  final title = args?['title'] as String?;
  final details = args?['details'] as String?;
  final status = args?['status'] as String? ?? 'todo';
  final memory = args?['memory'] as String?;
  
  if (requireString(projectId, 'project_id') case final error?) {
    return error;
  }
  
  if (requireString(title, 'title') case final error?) {
    return error;
  }
  
  if (requireOneOf(status, 'status', _validTaskStatuses) case final error?) {
    return error;
  }
  
  final id = _uuid.v4();
  final now = DateTime.now().toUtc().toIso8601String();
  
  final taskData = {
    'id': id,
    'project_id': projectId,
    'title': title,
    'details': details,
    'status': status,
    'memory': memory,
    'created_at': now,
    'updated_at': now,
  };
  
  // Wrap INSERT and transaction log in atomic transaction with retry
  withRetryTransactionSync(database, () {
    database.execute('''
      INSERT INTO tasks (id, project_id, title, details, status, memory, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''', [id, projectId, title, details, status, memory, now, now]);
    
    transactionLogRepository.log(
      entityType: EntityType.task,
      entityId: id,
      transactionType: TransactionType.create,
      summary: generateSummary(
        transactionType: TransactionType.create,
        entityType: EntityType.task,
        entityTitle: title!,
        projectId: projectId,
      ),
      changes: calculateChanges(
        transactionType: TransactionType.create,
        after: taskData,
      ),
      projectId: projectId,
    );
  });
  
  return jsonResult({
    'success': true,
    'message': 'Task created',
    'task': taskData,
  });
}

CallToolResult _showTask(Database database, Map<String, dynamic>? args) {
  final id = args?['id'] as String?;
  
  if (requireString(id, 'id') case final error?) {
    return error;
  }
  
  final taskResult = database.select('SELECT * FROM tasks WHERE id = ?', [id]);
  
  if (taskResult.isEmpty) {
    return notFoundError('Task', id!);
  }
  
  final task = taskResult.first;
  
  // Get steps for this task, ordered by sort_order with fallback to created_at
  // NULL sort_order values are placed at the end (9999999) to maintain backward compatibility
  final stepsResult = database.select(
    'SELECT id, title, status FROM steps WHERE task_id = ? ORDER BY COALESCE(sort_order, 9999999), created_at',
    [id]
  );
  
  final steps = stepsResult.map((row) => {
    'id': row['id'],
    'title': row['title'],
    'status': _normalizeStepStatus(row['status'] as String),
  }).toList();
  
  return jsonResult({
    'id': task['id'],
    'project_id': task['project_id'],
    'title': task['title'],
    'details': task['details'],
    'status': task['status'],
    'created_at': task['created_at'],
    'updated_at': task['updated_at'],
    'steps': steps,
  });
}

CallToolResult _updateTask(Database database, Map<String, dynamic>? args, TransactionLogRepository transactionLogRepository) {
  final id = args?['id'] as String?;
  
  if (requireString(id, 'id') case final error?) {
    return error;
  }
  
  // Get task before update for diff calculation
  final existingResult = database.select('SELECT * FROM tasks WHERE id = ?', [id]);
  if (existingResult.isEmpty) {
    return notFoundError('Task', id!);
  }
  
  final before = taskToLoggable(Map<String, dynamic>.from(existingResult.first));
  
  final updates = <String>[];
  final values = <Object?>[];
  
  if (args?.containsKey('project_id') == true) {
    updates.add('project_id = ?');
    values.add(args!['project_id']);
  }
  
  if (args?.containsKey('title') == true) {
    updates.add('title = ?');
    values.add(args!['title']);
  }
  
  if (args?.containsKey('details') == true) {
    updates.add('details = ?');
    values.add(args!['details']);
  }
  
  if (args?.containsKey('status') == true) {
    final status = args!['status'] as String;
    if (requireOneOf(status, 'status', _validTaskStatuses) case final error?) {
      return error;
    }
    updates.add('status = ?');
    values.add(status);
  }
  
  if (updates.isEmpty) {
    return validationError('fields', 'No fields to update');
  }
  
  final now = DateTime.now().toUtc().toIso8601String();
  updates.add('updated_at = ?');
  values.add(now);
  values.add(id);
  
  // Wrap UPDATE and transaction log in atomic transaction with retry
  withRetryTransactionSync(database, () {
    database.execute(
      'UPDATE tasks SET ${updates.join(", ")} WHERE id = ?',
      values
    );
    
    // Get task after update
    final afterResult = database.select('SELECT * FROM tasks WHERE id = ?', [id]);
    final after = taskToLoggable(Map<String, dynamic>.from(afterResult.first));
    
    // Calculate changes for audit
    final changes = calculateChanges(
      transactionType: TransactionType.update,
      before: before,
      after: after,
    );
    
    // Log the transaction
    transactionLogRepository.log(
      entityType: EntityType.task,
      entityId: id!,
      transactionType: TransactionType.update,
      summary: generateSummary(
        transactionType: TransactionType.update,
        entityType: EntityType.task,
        entityTitle: after['title'] as String,
        projectId: after['project_id'] as String?,
        changes: changes,
      ),
      changes: changes,
      projectId: after['project_id'] as String?,
    );
  });
  
  // Return updated task
  return _showTask(database, args);
}

CallToolResult _showTaskMemory(Database database, Map<String, dynamic>? args) {
  final id = args?['id'] as String?;
  
  if (requireString(id, 'id') case final error?) {
    return error;
  }
  
  final result = database.select('SELECT id, title, memory FROM tasks WHERE id = ?', [id]);
  
  if (result.isEmpty) {
    return notFoundError('Task', id!);
  }
  
  final task = result.first;
  final memory = task['memory'] as String?;
  
  return jsonResult({
    'id': task['id'],
    'title': task['title'],
    'memory': memory ?? '',
  });
}

CallToolResult _updateTaskMemory(Database database, Map<String, dynamic>? args, TransactionLogRepository transactionLogRepository) {
  final id = args?['id'] as String?;
  final memory = args?['memory'] as String?;
  
  if (requireString(id, 'id') case final error?) {
    return error;
  }
  
  // Get task before update for diff calculation
  final existingResult = database.select('SELECT * FROM tasks WHERE id = ?', [id]);
  if (existingResult.isEmpty) {
    return notFoundError('Task', id!);
  }
  
  final before = taskToLoggable(Map<String, dynamic>.from(existingResult.first));
  
  final now = DateTime.now().toUtc().toIso8601String();
  
  // Wrap UPDATE and transaction log in atomic transaction with retry
  withRetryTransactionSync(database, () {
    database.execute(
      'UPDATE tasks SET memory = ?, updated_at = ? WHERE id = ?',
      [memory, now, id]
    );
    
    // Get task after update
    final afterResult = database.select('SELECT * FROM tasks WHERE id = ?', [id]);
    final after = taskToLoggable(Map<String, dynamic>.from(afterResult.first));
    
    // Calculate changes for audit
    final changes = calculateChanges(
      transactionType: TransactionType.update,
      before: before,
      after: after,
    );
    
    // Log the transaction
    transactionLogRepository.log(
      entityType: EntityType.task,
      entityId: id!,
      transactionType: TransactionType.update,
      summary: generateSummary(
        transactionType: TransactionType.update,
        entityType: EntityType.task,
        entityTitle: after['title'] as String,
        projectId: after['project_id'] as String?,
        changes: changes,
      ),
      changes: changes,
      projectId: after['project_id'] as String?,
    );
  });
  
  return jsonResult({
    'success': true,
    'message': 'Task memory updated',
    'id': id,
  });
}

CallToolResult _listTasks(Database database, Map<String, dynamic>? args) {
  final projectId = args?['project_id'] as String?;
  final status = args?['status'] as String?;
  
  // Validate status if provided
  if (requireOneOf(status, 'status', _validTaskStatuses) case final error?) {
    return error;
  }
  
  // Build query with optional filters
  final conditions = <String>[];
  final values = <Object?>[];
  
  if (projectId != null && projectId.isNotEmpty) {
    conditions.add('t.project_id = ?');
    values.add(projectId);
  }
  
  if (status != null && status.isNotEmpty) {
    conditions.add('t.status = ?');
    values.add(status);
  }
  
  final whereClause = conditions.isEmpty ? '' : 'WHERE ${conditions.join(" AND ")}';
  
  // Query with step count subquery
  final query = '''
    SELECT 
      t.id,
      t.project_id,
      t.title,
      t.status,
      t.created_at,
      t.updated_at,
      (SELECT COUNT(*) FROM steps s WHERE s.task_id = t.id) as step_count
    FROM tasks t
    $whereClause
    ORDER BY t.updated_at DESC
  ''';
  
  final result = database.select(query, values);
  
  final tasks = result.map((row) => {
    'id': row['id'],
    'project_id': row['project_id'],
    'title': row['title'],
    'status': row['status'],
    'step_count': row['step_count'],
    'created_at': row['created_at'],
    'updated_at': row['updated_at'],
  }).toList();
  
  return jsonResult({
    'tasks': tasks,
    'count': tasks.length,
    'filters': {
      if (projectId != null) 'project_id': projectId,
      if (status != null) 'status': status,
    },
  });
}



// =============================================================================
// Step Operations
// =============================================================================

CallToolResult _addStep(Database database, Map<String, dynamic>? args, TransactionLogRepository transactionLogRepository) {
  final taskId = args?['task_id'] as String?;
  final title = args?['title'] as String?;
  final details = args?['details'] as String?;
  // Normalize legacy statuses for backward compatibility
  final status = _normalizeStepStatus(args?['status'] as String? ?? 'todo');
  
  if (requireString(taskId, 'task_id') case final error?) {
    return error;
  }
  
  if (requireString(title, 'title') case final error?) {
    return error;
  }
  
  if (requireOneOf(status, 'status', _validStepStatuses) case final error?) {
    return error;
  }
  
  // Check task exists and get task info for logging
  final taskResult = database.select('SELECT id, title, project_id FROM tasks WHERE id = ?', [taskId]);
  if (taskResult.isEmpty) {
    return notFoundError('Task', taskId!);
  }
  final taskInfo = taskResult.first;
  
  // Calculate sort_order for the new step (append to end)
  final countResult = database.select(
    'SELECT COUNT(*) as count FROM steps WHERE task_id = ?',
    [taskId]
  );
  final sortOrder = (countResult.first['count'] as int) + 1;
  
  final id = _uuid.v4();
  final now = DateTime.now().toUtc().toIso8601String();
  
  final stepData = {
    'id': id,
    'task_id': taskId,
    'title': title,
    'details': details,
    'status': status,
    'sort_order': sortOrder,
    'created_at': now,
    'updated_at': now,
  };
  
  // Wrap INSERT and transaction log in atomic transaction with retry
  withRetryTransactionSync(database, () {
    database.execute('''
      INSERT INTO steps (id, task_id, title, details, status, sort_order, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''', [id, taskId, title, details, status, sortOrder, now, now]);
    
    transactionLogRepository.log(
      entityType: EntityType.step,
      entityId: id,
      transactionType: TransactionType.create,
      summary: generateSummary(
        transactionType: TransactionType.create,
        entityType: EntityType.step,
        entityTitle: title!,
        taskTitle: taskInfo['title'] as String?,
      ),
      changes: calculateChanges(
        transactionType: TransactionType.create,
        after: stepData,
      ),
      projectId: taskInfo['project_id'] as String?,
    );
  });
  
  return jsonResult({
    'success': true,
    'message': 'Step created',
    'step': stepData,
  });
}

CallToolResult _showStep(Database database, Map<String, dynamic>? args) {
  final id = args?['id'] as String?;
  
  if (requireString(id, 'id') case final error?) {
    return error;
  }
  
  final result = database.select('SELECT * FROM steps WHERE id = ?', [id]);
  
  if (result.isEmpty) {
    return notFoundError('Step', id!);
  }
  
  final step = result.first;
  
  return jsonResult({
    'id': step['id'],
    'task_id': step['task_id'],
    'title': step['title'],
    'details': step['details'],
    'status': _normalizeStepStatus(step['status'] as String),
    'created_at': step['created_at'],
    'updated_at': step['updated_at'],
  });
}

CallToolResult _updateStep(Database database, Map<String, dynamic>? args, TransactionLogRepository transactionLogRepository) {
  final id = args?['id'] as String?;
  
  if (requireString(id, 'id') case final error?) {
    return error;
  }
  
  // Get step before update for diff calculation
  final existingResult = database.select('''
    SELECT s.*, t.title as task_title, t.project_id
    FROM steps s
    JOIN tasks t ON s.task_id = t.id
    WHERE s.id = ?
  ''', [id]);
  if (existingResult.isEmpty) {
    return notFoundError('Step', id!);
  }
  
  final existingRow = existingResult.first;
  final before = stepToLoggable(Map<String, dynamic>.from(existingRow));
  final projectId = existingRow['project_id'] as String?;
  
  final updates = <String>[];
  final values = <Object?>[];
  
  if (args?.containsKey('title') == true) {
    updates.add('title = ?');
    values.add(args!['title']);
  }
  
  if (args?.containsKey('details') == true) {
    updates.add('details = ?');
    values.add(args!['details']);
  }
  
  if (args?.containsKey('status') == true) {
    // Normalize legacy statuses for backward compatibility
    final status = _normalizeStepStatus(args!['status'] as String);
    if (requireOneOf(status, 'status', _validStepStatuses) case final error?) {
      return error;
    }
    updates.add('status = ?');
    values.add(status);
  }
  
  if (updates.isEmpty) {
    return validationError('fields', 'No fields to update');
  }
  
  final now = DateTime.now().toUtc().toIso8601String();
  updates.add('updated_at = ?');
  values.add(now);
  values.add(id);
  
  // Wrap UPDATE and transaction log in atomic transaction with retry
  withRetryTransactionSync(database, () {
    database.execute(
      'UPDATE steps SET ${updates.join(", ")} WHERE id = ?',
      values
    );
    
    // Get step after update
    final afterResult = database.select('SELECT * FROM steps WHERE id = ?', [id]);
    final after = stepToLoggable(Map<String, dynamic>.from(afterResult.first));
    
    // Calculate changes for audit
    final changes = calculateChanges(
      transactionType: TransactionType.update,
      before: before,
      after: after,
    );
    
    // Log the transaction
    transactionLogRepository.log(
      entityType: EntityType.step,
      entityId: id!,
      transactionType: TransactionType.update,
      summary: generateSummary(
        transactionType: TransactionType.update,
        entityType: EntityType.step,
        entityTitle: after['title'] as String,
        changes: changes,
      ),
      changes: changes,
      projectId: projectId,
    );
  });
  
  // Return updated step
  return _showStep(database, args);
}

// =============================================================================
// Timeline and Audit Operations
// =============================================================================

CallToolResult _getTimeline(Map<String, dynamic>? args, TransactionLogRepository transactionLogRepository) {
  final limit = (args?['limit'] as int?) ?? 20;
  final projectId = args?['project_id'] as String?;
  final entityTypeStr = args?['entity_type'] as String?;
  final beforeStr = args?['before'] as String?;
  final afterStr = args?['after'] as String?;
  
  // Parse entity type if provided
  EntityType? entityType;
  if (entityTypeStr != null) {
    try {
      entityType = EntityType.fromDbValue(entityTypeStr);
    } catch (e) {
      return validationError('entity_type', "Invalid entity_type. Must be 'task' or 'step'");
    }
  }
  
  // Parse datetime filters
  DateTime? before;
  DateTime? after;
  
  if (beforeStr != null) {
    try {
      before = DateTime.parse(beforeStr);
    } catch (e) {
      return validationError('before', 'Invalid before datetime format. Use ISO 8601 format.');
    }
  }
  
  if (afterStr != null) {
    try {
      after = DateTime.parse(afterStr);
    } catch (e) {
      return validationError('after', 'Invalid after datetime format. Use ISO 8601 format.');
    }
  }
  
  // Build query
  final query = TransactionLogQuery(
    entityType: entityType,
    projectId: projectId,
    before: before,
    after: after,
    limit: limit,
    newestFirst: true,
  );
  
  // Get timeline entries
  final entries = transactionLogRepository.getTimeline(query);
  
  // Format for output (timeline view - no detailed changes)
  final timeline = entries.map((entry) => entry.toTimelineJson()).toList();
  
  return jsonResult({
    'timeline': timeline,
    'count': timeline.length,
    'filters': {
      if (projectId != null) 'project_id': projectId,
      if (entityTypeStr != null) 'entity_type': entityTypeStr,
      if (beforeStr != null) 'before': beforeStr,
      if (afterStr != null) 'after': afterStr,
      'limit': limit,
    },
  });
}

CallToolResult _getAuditTrail(Map<String, dynamic>? args, TransactionLogRepository transactionLogRepository) {
  final entityTypeStr = args?['entity_type'] as String?;
  final entityId = args?['id'] as String?;
  final limit = (args?['limit'] as int?) ?? 100;
  
  // Validate required parameters
  if (requireString(entityTypeStr, 'entity_type') case final error?) {
    return error;
  }
  
  if (requireString(entityId, 'id') case final error?) {
    return error;
  }
  
  // Parse entity type
  EntityType entityType;
  try {
    entityType = EntityType.fromDbValue(entityTypeStr!);
  } catch (e) {
    return validationError('entity_type', "Invalid entity_type. Must be 'task' or 'step'");
  }
  
  // Get audit trail entries
  final entries = transactionLogRepository.getAuditTrail(
    entityType: entityType,
    entityId: entityId!,
    limit: limit,
    newestFirst: true,
  );
  
  // Format for output (full details including changes)
  final auditTrail = entries.map((entry) => entry.toJson()).toList();
  
  return jsonResult({
    'entity_type': entityTypeStr,
    'entity_id': entityId,
    'audit_trail': auditTrail,
    'count': auditTrail.length,
  });
}
