import 'dart:io';

import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:sqlite3/sqlite3.dart';

/// Current schema version. Increment when making schema changes.
const int currentSchemaVersion = 2;

/// Initialize the planner database with WAL mode and proper configuration.
Database initializeDatabase(String dbPath) {
  final database = sqlite3.open(dbPath);

  // Enable WAL mode for better concurrent access and crash recovery
  database.execute('PRAGMA journal_mode=WAL');

  // Set busy timeout to wait up to 5 seconds if database is locked
  database.execute('PRAGMA busy_timeout=5000');

  // Use NORMAL synchronous mode (good balance of safety and performance)
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
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON tasks(project_id)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_steps_task_id ON steps(task_id)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_steps_status ON steps(status)');

  // Run migrations to ensure schema is up to date
  _runMigrations(database);

  return database;
}

/// Get the current schema version from the database.
/// Returns 0 if no version has been set (fresh database).
int _getSchemaVersion(Database database) {
  final result = database
      .select("SELECT value FROM schema_metadata WHERE key = 'schema_version'");
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
  if (currentVersion < 1) {
    logInfo('planner', 'Running migration to schema version 1...');
    _setSchemaVersion(database, 1);
    logInfo('planner', 'Migration to schema version 1 complete.');
  }

  // Migration from version 1 to version 2
  // Add sort_order column for explicit step ordering
  if (currentVersion < 2) {
    logInfo('planner', 'Running migration to schema version 2...');
    database.execute('ALTER TABLE steps ADD COLUMN sort_order INTEGER');
    _setSchemaVersion(database, 2);
    logInfo('planner', 'Migration to schema version 2 complete.');
  }

  // Verify we're at the expected version
  final finalVersion = _getSchemaVersion(database);
  if (finalVersion != currentSchemaVersion) {
    logWarning('planner',
        'Schema version mismatch. Expected $currentSchemaVersion, got $finalVersion');
  }
}

/// Set up signal handlers for graceful shutdown.
void setupShutdownHandlers(Database database) {
  // Handle SIGINT (Ctrl+C)
  ProcessSignal.sigint.watch().listen((_) {
    logInfo('planner', 'Received SIGINT, closing database...');
    closeDatabase(database);
    exit(0);
  });

  // Handle SIGTERM
  ProcessSignal.sigterm.watch().listen((_) {
    logInfo('planner', 'Received SIGTERM, closing database...');
    closeDatabase(database);
    exit(0);
  });
}

/// Safely close the database.
void closeDatabase(Database database) {
  try {
    // Checkpoint WAL to main database before closing
    database.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    database.dispose();
    logInfo('planner', 'Database closed successfully');
  } catch (e, stackTrace) {
    logError('planner:close-database', e, stackTrace);
  }
}
