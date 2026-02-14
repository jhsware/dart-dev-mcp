import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:sqlite3/sqlite3.dart';

/// Current schema version. Increment when making schema changes.
const int currentSchemaVersion = 4;

/// Initialize the code-index database with WAL mode and proper configuration.
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

  // Create files table
  database.execute('''
    CREATE TABLE IF NOT EXISTS files (
      id TEXT PRIMARY KEY,
      path TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      description TEXT,
      file_type TEXT,
      file_hash TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');

  // Create exports table (methods, classes, class members)
  database.execute('''
    CREATE TABLE IF NOT EXISTS exports (
      id TEXT PRIMARY KEY,
      file_id TEXT NOT NULL,
      name TEXT NOT NULL,
      kind TEXT NOT NULL,
      parameters TEXT,
      description TEXT,
      parent_name TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    )
  ''');

  // Create variables table (exported/exposed variables)
  database.execute('''
    CREATE TABLE IF NOT EXISTS variables (
      id TEXT PRIMARY KEY,
      file_id TEXT NOT NULL,
      name TEXT NOT NULL,
      description TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    )
  ''');

  // Create imports table
  database.execute('''
    CREATE TABLE IF NOT EXISTS imports (
      id TEXT PRIMARY KEY,
      file_id TEXT NOT NULL,
      import_path TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    )
  ''');

  // Create indexes for files table
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_files_path ON files(path)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_files_file_type ON files(file_type)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_files_name ON files(name)');

  // Create indexes for exports table
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_exports_file_id ON exports(file_id)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_exports_name ON exports(name)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_exports_kind ON exports(kind)');

  // Create indexes for variables table
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_variables_file_id ON variables(file_id)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_variables_name ON variables(name)');

  // Create indexes for imports table
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_imports_file_id ON imports(file_id)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_imports_import_path ON imports(import_path)');

  // Create FTS5 virtual table for full-text search
  database.execute('''
    CREATE VIRTUAL TABLE IF NOT EXISTS code_search_fts USING fts5(
      file_id UNINDEXED,
      name,
      description,
      export_names,
      export_descriptions,
      variable_names,
      file_path
    )
  ''');

  // Create annotations table for TODO/FIXME/HACK tracking
  database.execute('''
    CREATE TABLE IF NOT EXISTS annotations (
      id TEXT PRIMARY KEY,
      file_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      message TEXT,
      line INTEGER,
      created_at TEXT NOT NULL,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    )
  ''');

  // Create indexes for annotations table
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_annotations_file_id ON annotations(file_id)');
  database.execute(
      'CREATE INDEX IF NOT EXISTS idx_annotations_kind ON annotations(kind)');

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
    logInfo('code-index', 'Running migration to schema version 1...');
    _setSchemaVersion(database, 1);
    logInfo('code-index', 'Migration to schema version 1 complete.');
  }

  // Migration from version 1 to version 2: Add FTS5
  if (currentVersion < 2) {
    logInfo('code-index', 'Running migration to schema version 2...');

    // Populate FTS from existing data
    database.execute('''
      INSERT INTO code_search_fts (file_id, name, description, export_names, export_descriptions, variable_names, file_path)
      SELECT 
        f.id,
        f.name,
        COALESCE(f.description, ''),
        COALESCE((SELECT GROUP_CONCAT(e.name, ' ') FROM exports e WHERE e.file_id = f.id), ''),
        COALESCE((SELECT GROUP_CONCAT(e.description, ' ') FROM exports e WHERE e.file_id = f.id AND e.description IS NOT NULL), ''),
        COALESCE((SELECT GROUP_CONCAT(v.name, ' ') FROM variables v WHERE v.file_id = f.id), ''),
        f.path
      FROM files f
    ''');

    _setSchemaVersion(database, 2);
    logInfo('code-index', 'Migration to schema version 2 complete.');
  }

  // Migration from version 2 to version 3: Add annotations table
  if (currentVersion < 3) {
    logInfo('code-index', 'Running migration to schema version 3...');
    // Table and indexes are created via CREATE IF NOT EXISTS above,
    // so just bump the version.
    _setSchemaVersion(database, 3);
    logInfo('code-index', 'Migration to schema version 3 complete.');
  }

  // Migration from version 3 to version 4: Add export_descriptions to FTS5
  if (currentVersion < 4) {
    logInfo('code-index', 'Running migration to schema version 4...');

    // Drop and recreate FTS table with new export_descriptions column
    database.execute('DROP TABLE IF EXISTS code_search_fts');
    database.execute('''
      CREATE VIRTUAL TABLE code_search_fts USING fts5(
        file_id UNINDEXED,
        name,
        description,
        export_names,
        export_descriptions,
        variable_names,
        file_path
      )
    ''');

    // Repopulate FTS from existing data including export descriptions
    database.execute('''
      INSERT INTO code_search_fts (file_id, name, description, export_names, export_descriptions, variable_names, file_path)
      SELECT 
        f.id,
        f.name,
        COALESCE(f.description, ''),
        COALESCE((SELECT GROUP_CONCAT(e.name, ' ') FROM exports e WHERE e.file_id = f.id), ''),
        COALESCE((SELECT GROUP_CONCAT(e.description, ' ') FROM exports e WHERE e.file_id = f.id AND e.description IS NOT NULL), ''),
        COALESCE((SELECT GROUP_CONCAT(v.name, ' ') FROM variables v WHERE v.file_id = f.id), ''),
        f.path
      FROM files f
    ''');

    _setSchemaVersion(database, 4);
    logInfo('code-index', 'Migration to schema version 4 complete.');
  }

  // Verify we're at the expected version
  final finalVersion = _getSchemaVersion(database);
  if (finalVersion != currentSchemaVersion) {
    logWarning('code-index',
        'Schema version mismatch. Expected $currentSchemaVersion, got $finalVersion');
  }
}

/// Set up signal handlers for graceful shutdown.
void setupShutdownHandlers(Database database) {
  // Handle SIGINT (Ctrl+C)
  ProcessSignal.sigint.watch().listen((_) {
    logInfo('code-index', 'Received SIGINT, closing database...');
    closeDatabase(database);
    exit(0);
  });

  // Handle SIGTERM
  ProcessSignal.sigterm.watch().listen((_) {
    logInfo('code-index', 'Received SIGTERM, closing database...');
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
    logInfo('code-index', 'Database closed successfully');
  } catch (e, stackTrace) {
    logError('code-index:close-database', e, stackTrace);
  }
}
