import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:sqlite3/sqlite3.dart';

/// Current schema version. Increment when making schema changes.
const int currentSchemaVersion = 8;

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
      sort_order INTEGER,
      sub_task_id TEXT,
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

  // Create items table (backlog items)
  database.execute('''
    CREATE TABLE IF NOT EXISTS items (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      title TEXT NOT NULL,
      details TEXT,
      type TEXT NOT NULL DEFAULT 'feature',
      status TEXT NOT NULL DEFAULT 'open',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');

  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_items_project_id ON items(project_id)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_items_type ON items(type)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_items_status ON items(status)');

  // Create item_history table
  database.execute('''
    CREATE TABLE IF NOT EXISTS item_history (
      id TEXT PRIMARY KEY,
      item_id TEXT NOT NULL,
      field_name TEXT NOT NULL,
      old_value TEXT,
      new_value TEXT,
      changed_at TEXT NOT NULL,
      FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
    )
  ''');

  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_item_history_item_id ON item_history(item_id)');

  // Create slate_history table
  database.execute('''
    CREATE TABLE IF NOT EXISTS slate_history (
      id TEXT PRIMARY KEY,
      slate_id TEXT NOT NULL,
      field_name TEXT NOT NULL,
      old_value TEXT,
      new_value TEXT,
      changed_at TEXT NOT NULL,
      FOREIGN KEY (slate_id) REFERENCES slates(id) ON DELETE CASCADE
    )
  ''');

  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_slate_history_slate_id ON slate_history(slate_id)');



  // Create slates table
  database.execute('''
    CREATE TABLE IF NOT EXISTS slates (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      title TEXT NOT NULL,
      notes TEXT,
      status TEXT NOT NULL DEFAULT 'draft',
      slate_date TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');

  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_slates_project_id ON slates(project_id)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_slates_status ON slates(status)');

  // Create slate_items junction table
  database.execute('''
    CREATE TABLE IF NOT EXISTS slate_items (
      slate_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      added_at TEXT NOT NULL,
      PRIMARY KEY (slate_id, item_id),
      FOREIGN KEY (slate_id) REFERENCES slates(id) ON DELETE CASCADE,
      FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
    )
  ''');

  // Create task_items junction table (links tasks to backlog items)
  database.execute('''
    CREATE TABLE IF NOT EXISTS task_items (
      task_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      added_at TEXT NOT NULL,
      PRIMARY KEY (task_id, item_id),
      FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
      FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
    )
  ''');

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

  // For a fresh database (version 0), the CREATE TABLE statements above
  // already include the full current schema, so we just set the version
  // to currentSchemaVersion and skip incremental migrations.
  if (currentVersion == 0) {
    logInfo('planner', 'Fresh database, setting schema version to $currentSchemaVersion.');
    _setSchemaVersion(database, currentSchemaVersion);
    return;
  }

  // Migration from version 1 to version 2
  // Add sort_order column for explicit step ordering
  if (currentVersion < 2) {
    logInfo('planner', 'Running migration to schema version 2...');
    database.execute('ALTER TABLE steps ADD COLUMN sort_order INTEGER');
    _setSchemaVersion(database, 2);
    logInfo('planner', 'Migration to schema version 2 complete.');
  }

  // Migration from version 2 to version 3
  // Add sub_task_id column for step-to-subtask references
  if (currentVersion < 3) {
    logInfo('planner', 'Running migration to schema version 3...');
    database.execute('ALTER TABLE steps ADD COLUMN sub_task_id TEXT');
    _setSchemaVersion(database, 3);
    logInfo('planner', 'Migration to schema version 3 complete.');
  }

  // Migration from version 3 to version 4
  // Add backlog tables: items, item_history, slates, slate_items, task_items
  // Uses CREATE TABLE IF NOT EXISTS for compatibility with viewer app
  if (currentVersion < 4) {
    logInfo('planner', 'Running migration to schema version 4...');

    database.execute('''
      CREATE TABLE IF NOT EXISTS items (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        title TEXT NOT NULL,
        details TEXT,
        type TEXT NOT NULL DEFAULT 'feature',
        status TEXT NOT NULL DEFAULT 'open',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    database.execute(
        'CREATE INDEX IF NOT EXISTS idx_items_project_id ON items(project_id)');
    database.execute(
        'CREATE INDEX IF NOT EXISTS idx_items_type ON items(type)');
    database.execute(
        'CREATE INDEX IF NOT EXISTS idx_items_status ON items(status)');

    database.execute('''
      CREATE TABLE IF NOT EXISTS item_history (
        id TEXT PRIMARY KEY,
        item_id TEXT NOT NULL,
        field_name TEXT NOT NULL,
        old_value TEXT,
        new_value TEXT,
        changed_at TEXT NOT NULL,
        FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
      )
    ''');
    database.execute(
        'CREATE INDEX IF NOT EXISTS idx_item_history_item_id ON item_history(item_id)');

    database.execute('''
      CREATE TABLE IF NOT EXISTS slates (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        title TEXT NOT NULL,
        notes TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    database.execute(
        'CREATE INDEX IF NOT EXISTS idx_slates_project_id ON slates(project_id)');

    database.execute('''
      CREATE TABLE IF NOT EXISTS slate_items (
        slate_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        added_at TEXT NOT NULL,
        PRIMARY KEY (slate_id, item_id),
        FOREIGN KEY (slate_id) REFERENCES slates(id) ON DELETE CASCADE,
        FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
      )
    ''');

    database.execute('''
      CREATE TABLE IF NOT EXISTS task_items (
        task_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        added_at TEXT NOT NULL,
        PRIMARY KEY (task_id, item_id),
        FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
        FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE
      )
    ''');

    _setSchemaVersion(database, 4);
    logInfo('planner', 'Migration to schema version 4 complete.');
  }

  // Migration from version 4 to version 5
  // Add status and slate_date columns to slates table
  if (currentVersion < 5) {
    logInfo('planner', 'Running migration to schema version 5...');
    
    // Check if columns already exist (defensive, in case CREATE TABLE already included them)
    final columns = database.select("PRAGMA table_info(slates)");
    final columnNames = columns.map((row) => row['name'] as String).toSet();
    
    if (!columnNames.contains('status')) {
      database.execute("ALTER TABLE slates ADD COLUMN status TEXT NOT NULL DEFAULT 'draft'");
    }
    if (!columnNames.contains('slate_date')) {
      database.execute('ALTER TABLE slates ADD COLUMN slate_date TEXT');
    }
    database.execute('CREATE INDEX IF NOT EXISTS idx_slates_status ON slates(status)');
    _setSchemaVersion(database, 5);
    logInfo('planner', 'Migration to schema version 5 complete.');
  }

  // Migration from version 5 to version 6
  // Rename release tables/columns/data to slate nomenclature
  // For existing databases that still have the old 'releases' table names
  if (currentVersion < 6) {
    logInfo('planner', 'Running migration to schema version 6...');

    // Check if old 'releases' table exists (it won't for fresh databases
    // that went through updated v4 migration creating 'slates' directly)
    final tables = database.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='releases'");
    
    if (tables.isNotEmpty) {
      // The CREATE TABLE IF NOT EXISTS statements above may have already
      // created empty 'slates' and 'slate_items' tables. We need to drop
      // them before renaming the old tables that contain the actual data.
      database.execute('DROP TABLE IF EXISTS slate_items');
      database.execute('DROP TABLE IF EXISTS slates');

      // Rename tables
      database.execute('ALTER TABLE releases RENAME TO slates');
      database.execute('ALTER TABLE release_items RENAME TO slate_items');

      // Rename columns (SQLite supports RENAME COLUMN since 3.25.0)
      database.execute('ALTER TABLE slates RENAME COLUMN release_date TO slate_date');
      database.execute('ALTER TABLE slate_items RENAME COLUMN release_id TO slate_id');

      // Drop old indexes and recreate with new names
      database.execute('DROP INDEX IF EXISTS idx_releases_project_id');
      database.execute('DROP INDEX IF EXISTS idx_releases_status');
      database.execute('CREATE INDEX IF NOT EXISTS idx_slates_project_id ON slates(project_id)');
      database.execute('CREATE INDEX IF NOT EXISTS idx_slates_status ON slates(status)');
    }

    // Update transaction log entity_type values
    database.execute("UPDATE transaction_logs SET entity_type = 'slate' WHERE entity_type = 'release'");

    _setSchemaVersion(database, 6);
    logInfo('planner', 'Migration to schema version 6 complete.');
  }

  // Migration from version 6 to version 7
  // Add missing added_at column to task_items and slate_items tables.
  // External tools (e.g. viewer apps) may have created these tables without
  // the added_at column, and CREATE TABLE IF NOT EXISTS won't add it.
  if (currentVersion < 7) {
    logInfo('planner', 'Running migration to schema version 7...');

    // Check task_items for missing added_at column
    final taskItemsCols = database.select("PRAGMA table_info(task_items)");
    final taskItemsColNames =
        taskItemsCols.map((row) => row['name'] as String).toSet();

    if (!taskItemsColNames.contains('added_at')) {
      final now = DateTime.now().toUtc().toIso8601String();
      database.execute(
          "ALTER TABLE task_items ADD COLUMN added_at TEXT NOT NULL DEFAULT '$now'");
    }

    // Check slate_items for missing added_at column
    final slateItemsCols = database.select("PRAGMA table_info(slate_items)");
    final slateItemsColNames =
        slateItemsCols.map((row) => row['name'] as String).toSet();

    if (!slateItemsColNames.contains('added_at')) {
      final now = DateTime.now().toUtc().toIso8601String();
      database.execute(
          "ALTER TABLE slate_items ADD COLUMN added_at TEXT NOT NULL DEFAULT '$now'");
    }

    _setSchemaVersion(database, 7);
    logInfo('planner', 'Migration to schema version 7 complete.');
  }

  // Migration from version 7 to version 8
  // Add slate_history table for per-field change tracking on slates
  if (currentVersion < 8) {
    logInfo('planner', 'Running migration to schema version 8...');
    database.execute('''
      CREATE TABLE IF NOT EXISTS slate_history (
        id TEXT PRIMARY KEY,
        slate_id TEXT NOT NULL,
        field_name TEXT NOT NULL,
        old_value TEXT,
        new_value TEXT,
        changed_at TEXT NOT NULL,
        FOREIGN KEY (slate_id) REFERENCES slates(id) ON DELETE CASCADE
      )
    ''');
    database.execute(
        'CREATE INDEX IF NOT EXISTS idx_slate_history_slate_id ON slate_history(slate_id)');
    _setSchemaVersion(database, 8);
    logInfo('planner', 'Migration to schema version 8 complete.');
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
