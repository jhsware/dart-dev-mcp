import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

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
  final db = _initializeDatabase(dbPath);

  stderr.writeln('Planner MCP Server starting...');
  stderr.writeln('Project path: ${workingDir.path}');
  stderr.writeln('Database: $dbPath');

  // Set up graceful shutdown to close database
  _setupShutdownHandlers(db);

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

Task statuses: todo, started, canceled, done
Step statuses: todo, started, canceled, done, merged''',
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
          ],
        },
        'id': {
          'type': 'string',
          'description': 'Task or step ID (for show/update operations)',
        },
        'task_id': {
          'type': 'string',
          'description': 'Parent task ID (for add-step)',
        },
        'project_id': {
          'type': 'string',
          'description': 'Project identifier (for add-task, list-tasks filter)',
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
          'description': 'Status: todo, started, canceled, done (or merged for steps). Also used for list-tasks filter.',
          'enum': ['todo', 'started', 'canceled', 'done', 'merged'],
        },
        'memory': {
          'type': 'string',
          'description': 'Memory/notes content for task',
        },
      },
    ),
    callback: ({args, extra}) => _handlePlanner(args, workingDir, db),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  stderr.writeln('Planner MCP Server running on stdio');
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
void _setupShutdownHandlers(Database db) {
  // Handle SIGINT (Ctrl+C)
  ProcessSignal.sigint.watch().listen((_) {
    stderr.writeln('Received SIGINT, closing database...');
    _closeDatabase(db);
    exit(0);
  });

  // Handle SIGTERM
  ProcessSignal.sigterm.watch().listen((_) {
    stderr.writeln('Received SIGTERM, closing database...');
    _closeDatabase(db);
    exit(0);
  });
}

/// Safely close the database
void _closeDatabase(Database db) {
  try {
    // Checkpoint WAL to main database before closing
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    db.dispose();
    stderr.writeln('Database closed successfully');
  } catch (e) {
    stderr.writeln('Error closing database: $e');
  }
}

CallToolResult _textResult(String text) {
  return CallToolResult.fromContent(
    content: [TextContent(text: text)],
  );
}

CallToolResult _jsonResult(Map<String, dynamic> data) {
  return CallToolResult.fromContent(
    content: [TextContent(text: JsonEncoder.withIndent('  ').convert(data))],
  );
}

// =============================================================================
// Database Initialization
// =============================================================================

Database _initializeDatabase(String dbPath) {
  final db = sqlite3.open(dbPath);
  
  // Enable WAL mode for better concurrent access and crash recovery
  // WAL mode is more resilient to corruption from unexpected shutdowns
  db.execute('PRAGMA journal_mode=WAL');
  
  // Set busy timeout to wait up to 5 seconds if database is locked
  db.execute('PRAGMA busy_timeout=5000');
  
  // Use NORMAL synchronous mode (good balance of safety and performance)
  // FULL is safer but slower, NORMAL is safe for WAL mode
  db.execute('PRAGMA synchronous=NORMAL');
  
  // Enable foreign key enforcement
  db.execute('PRAGMA foreign_keys=ON');
  
  // Create tasks table
  db.execute('''
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
  db.execute('''
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
  db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON tasks(project_id)');
  db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)');
  db.execute('CREATE INDEX IF NOT EXISTS idx_steps_task_id ON steps(task_id)');
  db.execute('CREATE INDEX IF NOT EXISTS idx_steps_status ON steps(status)');
  
  return db;
}

// =============================================================================
// Main Handler
// =============================================================================

Future<CallToolResult> _handlePlanner(
  Map<String, dynamic>? args,
  Directory workingDir,
  Database db,
) async {
  final operation = args?['operation'] as String?;

  if (operation == null) {
    return _textResult('Error: operation is required');
  }

  try {
    switch (operation) {
      case 'get-project-instructions':
        return _getProjectInstructions(workingDir);
      case 'add-task':
        return _addTask(db, args);
      case 'show-task':
        return _showTask(db, args);
      case 'update-task':
        return _updateTask(db, args);
      case 'show-task-memory':
        return _showTaskMemory(db, args);
      case 'update-task-memory':
        return _updateTaskMemory(db, args);
      case 'add-step':
        return _addStep(db, args);
      case 'show-step':
        return _showStep(db, args);
      case 'update-step':
        return _updateStep(db, args);
      default:
        return _textResult('Error: Unknown operation: $operation');
    }
  } on SqliteException catch (e) {
    // Handle SQLite-specific errors with more detail
    stderr.writeln('SQLite error: $e');
    return _textResult('Database error: ${e.message}');
  } catch (e) {
    stderr.writeln('Error in planner operation: $e');
    return _textResult('Error: $e');
  }
}

// =============================================================================
// Project Instructions
// =============================================================================

Future<CallToolResult> _getProjectInstructions(Directory workingDir) async {
  final instructionsPath = p.join(workingDir.path, '.ai_coding_tool', 'INSTRUCTIONS.md');
  final file = File(instructionsPath);
  
  if (!await file.exists()) {
    return _textResult(
      'No project instructions found.\n'
      'Create a file at: .ai_coding_tool/INSTRUCTIONS.md'
    );
  }
  
  final content = await file.readAsString();
  return _textResult(content);
}

// =============================================================================
// Task Operations
// =============================================================================

final _uuid = Uuid();

const _validTaskStatuses = ['todo', 'started', 'canceled', 'done'];
const _validStepStatuses = ['todo', 'started', 'canceled', 'done', 'merged'];

CallToolResult _addTask(Database db, Map<String, dynamic>? args) {
  final projectId = args?['project_id'] as String?;
  final title = args?['title'] as String?;
  final details = args?['details'] as String?;
  final status = args?['status'] as String? ?? 'todo';
  final memory = args?['memory'] as String?;
  
  if (projectId == null || projectId.isEmpty) {
    return _textResult('Error: project_id is required');
  }
  
  if (title == null || title.isEmpty) {
    return _textResult('Error: title is required');
  }
  
  if (!_validTaskStatuses.contains(status)) {
    return _textResult('Error: Invalid status. Must be one of: ${_validTaskStatuses.join(", ")}');
  }
  
  final id = _uuid.v4();
  final now = DateTime.now().toUtc().toIso8601String();
  
  db.execute('''
    INSERT INTO tasks (id, project_id, title, details, status, memory, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ''', [id, projectId, title, details, status, memory, now, now]);
  
  return _jsonResult({
    'success': true,
    'message': 'Task created',
    'task': {
      'id': id,
      'project_id': projectId,
      'title': title,
      'details': details,
      'status': status,
      'memory': memory,
      'created_at': now,
      'updated_at': now,
    },
  });
}

CallToolResult _showTask(Database db, Map<String, dynamic>? args) {
  final id = args?['id'] as String?;
  
  if (id == null || id.isEmpty) {
    return _textResult('Error: id is required');
  }
  
  final taskResult = db.select('SELECT * FROM tasks WHERE id = ?', [id]);
  
  if (taskResult.isEmpty) {
    return _textResult('Error: Task not found: $id');
  }
  
  final task = taskResult.first;
  
  // Get steps for this task
  final stepsResult = db.select(
    'SELECT id, title, status FROM steps WHERE task_id = ? ORDER BY created_at',
    [id]
  );
  
  final steps = stepsResult.map((row) => {
    'id': row['id'],
    'title': row['title'],
    'status': row['status'],
  }).toList();
  
  return _jsonResult({
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

CallToolResult _updateTask(Database db, Map<String, dynamic>? args) {
  final id = args?['id'] as String?;
  
  if (id == null || id.isEmpty) {
    return _textResult('Error: id is required');
  }
  
  // Check task exists
  final existing = db.select('SELECT id FROM tasks WHERE id = ?', [id]);
  if (existing.isEmpty) {
    return _textResult('Error: Task not found: $id');
  }
  
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
    if (!_validTaskStatuses.contains(status)) {
      return _textResult('Error: Invalid status. Must be one of: ${_validTaskStatuses.join(", ")}');
    }
    updates.add('status = ?');
    values.add(status);
  }
  
  if (updates.isEmpty) {
    return _textResult('Error: No fields to update');
  }
  
  final now = DateTime.now().toUtc().toIso8601String();
  updates.add('updated_at = ?');
  values.add(now);
  values.add(id);
  
  db.execute(
    'UPDATE tasks SET ${updates.join(", ")} WHERE id = ?',
    values
  );
  
  // Return updated task
  return _showTask(db, args);
}

CallToolResult _showTaskMemory(Database db, Map<String, dynamic>? args) {
  final id = args?['id'] as String?;
  
  if (id == null || id.isEmpty) {
    return _textResult('Error: id is required');
  }
  
  final result = db.select('SELECT id, title, memory FROM tasks WHERE id = ?', [id]);
  
  if (result.isEmpty) {
    return _textResult('Error: Task not found: $id');
  }
  
  final task = result.first;
  final memory = task['memory'] as String?;
  
  return _jsonResult({
    'id': task['id'],
    'title': task['title'],
    'memory': memory ?? '',
  });
}

CallToolResult _updateTaskMemory(Database db, Map<String, dynamic>? args) {
  final id = args?['id'] as String?;
  final memory = args?['memory'] as String?;
  
  if (id == null || id.isEmpty) {
    return _textResult('Error: id is required');
  }
  
  // Check task exists
  final existing = db.select('SELECT id FROM tasks WHERE id = ?', [id]);
  if (existing.isEmpty) {
    return _textResult('Error: Task not found: $id');
  }
  
  final now = DateTime.now().toUtc().toIso8601String();
  
  db.execute(
    'UPDATE tasks SET memory = ?, updated_at = ? WHERE id = ?',
    [memory, now, id]
  );
  
  return _jsonResult({
    'success': true,
    'message': 'Task memory updated',
    'id': id,
  });
}

CallToolResult _listTasks(Database db, Map<String, dynamic>? args) {
  final projectId = args?['project_id'] as String?;
  final status = args?['status'] as String?;
  
  // Validate status if provided
  if (status != null && !_validTaskStatuses.contains(status)) {
    return _textResult('Error: Invalid status filter. Must be one of: ${_validTaskStatuses.join(", ")}');
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
  
  final result = db.select(query, values);
  
  final tasks = result.map((row) => {
    'id': row['id'],
    'project_id': row['project_id'],
    'title': row['title'],
    'status': row['status'],
    'step_count': row['step_count'],
    'created_at': row['created_at'],
    'updated_at': row['updated_at'],
  }).toList();
  
  return _jsonResult({
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

CallToolResult _addStep(Database db, Map<String, dynamic>? args) {
  final taskId = args?['task_id'] as String?;
  final title = args?['title'] as String?;
  final details = args?['details'] as String?;
  final status = args?['status'] as String? ?? 'todo';
  
  if (taskId == null || taskId.isEmpty) {
    return _textResult('Error: task_id is required');
  }
  
  if (title == null || title.isEmpty) {
    return _textResult('Error: title is required');
  }
  
  if (!_validStepStatuses.contains(status)) {
    return _textResult('Error: Invalid status. Must be one of: ${_validStepStatuses.join(", ")}');
  }
  
  // Check task exists
  final taskExists = db.select('SELECT id FROM tasks WHERE id = ?', [taskId]);
  if (taskExists.isEmpty) {
    return _textResult('Error: Task not found: $taskId');
  }
  
  final id = _uuid.v4();
  final now = DateTime.now().toUtc().toIso8601String();
  
  db.execute('''
    INSERT INTO steps (id, task_id, title, details, status, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  ''', [id, taskId, title, details, status, now, now]);
  
  return _jsonResult({
    'success': true,
    'message': 'Step created',
    'step': {
      'id': id,
      'task_id': taskId,
      'title': title,
      'details': details,
      'status': status,
      'created_at': now,
      'updated_at': now,
    },
  });
}

CallToolResult _showStep(Database db, Map<String, dynamic>? args) {
  final id = args?['id'] as String?;
  
  if (id == null || id.isEmpty) {
    return _textResult('Error: id is required');
  }
  
  final result = db.select('SELECT * FROM steps WHERE id = ?', [id]);
  
  if (result.isEmpty) {
    return _textResult('Error: Step not found: $id');
  }
  
  final step = result.first;
  
  return _jsonResult({
    'id': step['id'],
    'task_id': step['task_id'],
    'title': step['title'],
    'details': step['details'],
    'status': step['status'],
    'created_at': step['created_at'],
    'updated_at': step['updated_at'],
  });
}

CallToolResult _updateStep(Database db, Map<String, dynamic>? args) {
  final id = args?['id'] as String?;
  
  if (id == null || id.isEmpty) {
    return _textResult('Error: id is required');
  }
  
  // Check step exists
  final existing = db.select('SELECT id FROM steps WHERE id = ?', [id]);
  if (existing.isEmpty) {
    return _textResult('Error: Step not found: $id');
  }
  
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
    final status = args!['status'] as String;
    if (!_validStepStatuses.contains(status)) {
      return _textResult('Error: Invalid status. Must be one of: ${_validStepStatuses.join(", ")}');
    }
    updates.add('status = ?');
    values.add(status);
  }
  
  if (updates.isEmpty) {
    return _textResult('Error: No fields to update');
  }
  
  final now = DateTime.now().toUtc().toIso8601String();
  updates.add('updated_at = ?');
  values.add(now);
  values.add(id);
  
  db.execute(
    'UPDATE steps SET ${updates.join(", ")} WHERE id = ?',
    values
  );
  
  // Return updated step
  return _showStep(db, args);
}
