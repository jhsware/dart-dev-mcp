import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:sqlite3/sqlite3.dart';

/// Schema version stamp for diagnostics. This is a clean-break schema —
/// no migrations exist. If the version on disk differs, the database is
/// discarded and rebuilt from scratch via [rebuildDatabase].
const int schemaVersion = 1;

/// Initialize the code-index database with WAL mode and the full v1 schema.
///
/// This must only be called on a freshly-created (empty) database file.
/// For re-indexing, use [rebuildDatabase] which deletes the old file first.
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

  _createSchema(database);

  return database;
}

/// Delete the existing database (and WAL/SHM sidecars) then create a fresh
/// one via [initializeDatabase].
///
/// If [existingDb] is provided it will be disposed before the files are
/// deleted — call this when you hold an open connection.
Database rebuildDatabase(String dbPath, {Database? existingDb}) {
  if (existingDb != null) {
    try {
      existingDb.dispose();
    } catch (_) {
      // Best-effort — the DB may already be closed.
    }
  }

  // Delete the main DB file and WAL/SHM sidecars.
  for (final suffix in ['', '-wal', '-shm']) {
    final f = File('$dbPath$suffix');
    if (f.existsSync()) {
      f.deleteSync();
    }
  }

  return initializeDatabase(dbPath);
}

/// Create all tables, indexes, and FTS5 virtual tables in one pass.
void _createSchema(Database db) {
  // -- files -----------------------------------------------------------------
  db.execute('''
    CREATE TABLE files (
      id TEXT PRIMARY KEY,
      path TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      description TEXT,
      file_type TEXT,
      file_hash TEXT NOT NULL,
      size_bytes INTEGER,
      line_count INTEGER,
      word_count INTEGER,
      mtime TEXT,
      short_summary TEXT,
      layers_present TEXT,
      last_analyzed_at TEXT,
      analysis_status TEXT NOT NULL DEFAULT 'pending',
      analysis_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');

  db.execute('CREATE INDEX idx_files_path ON files(path)');
  db.execute('CREATE INDEX idx_files_file_type ON files(file_type)');
  db.execute('CREATE INDEX idx_files_name ON files(name)');
  db.execute(
      'CREATE INDEX idx_files_analysis_status ON files(analysis_status)');

  // -- exports (layer 2 declarations + layer 3 per-symbol summaries) ---------
  db.execute('''
    CREATE TABLE exports (
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

  db.execute('CREATE INDEX idx_exports_file_id ON exports(file_id)');
  db.execute('CREATE INDEX idx_exports_name ON exports(name)');
  db.execute('CREATE INDEX idx_exports_kind ON exports(kind)');

  // -- variables -------------------------------------------------------------
  db.execute('''
    CREATE TABLE variables (
      id TEXT PRIMARY KEY,
      file_id TEXT NOT NULL,
      name TEXT NOT NULL,
      description TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    )
  ''');

  db.execute('CREATE INDEX idx_variables_file_id ON variables(file_id)');
  db.execute('CREATE INDEX idx_variables_name ON variables(name)');

  // -- imports ---------------------------------------------------------------
  db.execute('''
    CREATE TABLE imports (
      id TEXT PRIMARY KEY,
      file_id TEXT NOT NULL,
      import_path TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    )
  ''');

  db.execute('CREATE INDEX idx_imports_file_id ON imports(file_id)');
  db.execute('CREATE INDEX idx_imports_import_path ON imports(import_path)');

  // -- annotations -----------------------------------------------------------
  db.execute('''
    CREATE TABLE annotations (
      id TEXT PRIMARY KEY,
      file_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      message TEXT,
      line INTEGER,
      created_at TEXT NOT NULL,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    )
  ''');

  db.execute(
      'CREATE INDEX idx_annotations_file_id ON annotations(file_id)');
  db.execute(
      'CREATE INDEX idx_annotations_kind ON annotations(kind)');

  // -- external_symbol_usages (§5a.3 dot-notation references) ----------------
  db.execute('''
    CREATE TABLE external_symbol_usages (
      id TEXT PRIMARY KEY,
      file_id TEXT NOT NULL,
      module TEXT NOT NULL,
      source_path TEXT NOT NULL,
      symbol TEXT NOT NULL,
      symbol_kind TEXT,
      dot_path TEXT NOT NULL,
      reference_count INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
      UNIQUE(file_id, dot_path)
    )
  ''');

  db.execute(
      'CREATE INDEX idx_ext_usages_symbol ON external_symbol_usages(symbol)');
  db.execute(
      'CREATE INDEX idx_ext_usages_module ON external_symbol_usages(module)');
  db.execute(
      'CREATE INDEX idx_ext_usages_dot_path ON external_symbol_usages(dot_path)');

  // -- FTS5 full-text search -------------------------------------------------
  db.execute('''
    CREATE VIRTUAL TABLE code_search_fts USING fts5(
      file_id UNINDEXED,
      name,
      description,
      export_names,
      export_descriptions,
      variable_names,
      file_path,
      external_symbols
    )
  ''');
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
