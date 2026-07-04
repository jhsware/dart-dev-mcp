import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:sqlite3/sqlite3.dart';

/// Schema version stamp, stored in `PRAGMA user_version`. This is a
/// clean-break schema — no migrations exist. If the version on disk differs,
/// the database is discarded and rebuilt from scratch via [rebuildDatabase].
const int schemaVersion = 2;

/// Apply the standard connection PRAGMAs (WAL, busy timeout, synchronous,
/// foreign keys) to an open [database].
void _applyPragmas(Database database) {
  database.execute('PRAGMA journal_mode=WAL');
  database.execute('PRAGMA busy_timeout=5000');
  database.execute('PRAGMA synchronous=NORMAL');
  database.execute('PRAGMA foreign_keys=ON');
}

/// Initialize the code-index database with the full v2 schema and stamp
/// `PRAGMA user_version = schemaVersion`.
///
/// This must only be called on a freshly-created (empty) database file.
/// For re-indexing, use [rebuildDatabase] which deletes the old file first.
Database initializeDatabase(String dbPath) {
  final database = sqlite3.open(dbPath);
  _applyPragmas(database);
  _createSchema(database);
  database.execute('PRAGMA user_version=$schemaVersion');
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

/// Open the database at [dbPath], rebuilding it from scratch when the stored
/// `user_version` does not match [schemaVersion] (design §3.4). A brand-new
/// (empty) file is initialized with the current schema.
Database openOrRebuild(String dbPath) {
  final exists = File(dbPath).existsSync();
  if (!exists) {
    return initializeDatabase(dbPath);
  }

  final database = sqlite3.open(dbPath);
  final result = database.select('PRAGMA user_version');
  final version = result.isNotEmpty ? result.first.values.first as int : 0;
  if (version == schemaVersion) {
    _applyPragmas(database);
    return database;
  }

  logInfo('code-index',
      'Schema version $version != $schemaVersion, rebuilding database');
  return rebuildDatabase(dbPath, existingDb: database);
}

/// Create all tables, indexes, and the FTS5 virtual table in one pass
/// (design §6).
void _createSchema(Database db) {
  // -- files -----------------------------------------------------------------
  db.execute('''
    CREATE TABLE files (
      id                      TEXT PRIMARY KEY,
      path                    TEXT NOT NULL UNIQUE,
      name                    TEXT NOT NULL,
      file_type               TEXT,
      language                TEXT,
      file_hash               TEXT NOT NULL,
      size_bytes              INTEGER NOT NULL,
      line_count              INTEGER NOT NULL,
      word_count              INTEGER NOT NULL,
      mtime                   TEXT NOT NULL,
      summary                 TEXT,
      tags                    TEXT,
      layers_present          TEXT NOT NULL,
      indexed_at              TEXT,
      structure_refreshed_at  TEXT,
      analysis_status         TEXT NOT NULL DEFAULT 'pending',
      analysis_error          TEXT,
      created_at              TEXT NOT NULL,
      updated_at              TEXT NOT NULL
    )
  ''');

  db.execute('CREATE INDEX idx_files_path     ON files(path)');
  db.execute('CREATE INDEX idx_files_name     ON files(name)');
  db.execute('CREATE INDEX idx_files_type     ON files(file_type)');
  db.execute('CREATE INDEX idx_files_language ON files(language)');
  db.execute('CREATE INDEX idx_files_status   ON files(analysis_status)');

  // -- symbols (merges v1's exports + variables) -----------------------------
  db.execute('''
    CREATE TABLE symbols (
      id         TEXT PRIMARY KEY,
      file_id    TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      name       TEXT NOT NULL,
      kind       TEXT NOT NULL,
      visibility TEXT NOT NULL DEFAULT 'public',
      parent     TEXT,
      signature  TEXT,
      line       INTEGER,
      end_line   INTEGER,
      summary    TEXT,
      created_at TEXT NOT NULL
    )
  ''');

  db.execute('CREATE INDEX idx_symbols_file ON symbols(file_id)');
  db.execute('CREATE INDEX idx_symbols_name ON symbols(name)');
  db.execute('CREATE INDEX idx_symbols_kind ON symbols(kind)');

  // -- imports ---------------------------------------------------------------
  db.execute('''
    CREATE TABLE imports (
      id          TEXT PRIMARY KEY,
      file_id     TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      import_path TEXT NOT NULL,
      created_at  TEXT NOT NULL
    )
  ''');

  db.execute('CREATE INDEX idx_imports_file ON imports(file_id)');
  db.execute('CREATE INDEX idx_imports_path ON imports(import_path)');

  // -- symbol_references (v1's external_symbol_usages, carried forward) -------
  db.execute('''
    CREATE TABLE symbol_references (
      id          TEXT PRIMARY KEY,
      file_id     TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      symbol      TEXT NOT NULL,
      module      TEXT NOT NULL,
      source_path TEXT,
      dot_path    TEXT NOT NULL,
      symbol_kind TEXT,
      resolution  TEXT NOT NULL,
      count       INTEGER NOT NULL DEFAULT 1,
      created_at  TEXT NOT NULL,
      UNIQUE(file_id, dot_path)
    )
  ''');

  db.execute('CREATE INDEX idx_refs_symbol   ON symbol_references(symbol)');
  db.execute('CREATE INDEX idx_refs_module   ON symbol_references(module)');
  db.execute('CREATE INDEX idx_refs_dot_path ON symbol_references(dot_path)');

  // -- annotations -----------------------------------------------------------
  db.execute('''
    CREATE TABLE annotations (
      id         TEXT PRIMARY KEY,
      file_id    TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      kind       TEXT NOT NULL,
      message    TEXT,
      line       INTEGER,
      created_at TEXT NOT NULL
    )
  ''');

  db.execute('CREATE INDEX idx_annotations_file ON annotations(file_id)');
  db.execute('CREATE INDEX idx_annotations_kind ON annotations(kind)');

  // -- FTS5 full-text search -------------------------------------------------
  db.execute('''
    CREATE VIRTUAL TABLE code_index_fts USING fts5(
      file_id UNINDEXED,
      path,
      name,
      summary,
      tags,
      symbol_names,
      symbol_summaries,
      reference_symbols
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
