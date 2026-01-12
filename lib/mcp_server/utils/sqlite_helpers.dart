/// SQLite helper utilities for robust database operations.
///
/// Provides transaction management, retry logic, and error classification
/// for SQLite database operations.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart';

// =============================================================================
// Transaction Management
// =============================================================================

/// Executes a database operation within an explicit transaction.
///
/// Ensures atomicity: either all changes commit or all are rolled back.
/// This is essential for multi-statement operations that should be atomic,
/// such as inserting a record and logging the transaction.
///
/// ```dart
/// final result = withTransaction(db, () {
///   db.execute('INSERT INTO tasks ...', [...]);
///   db.execute('INSERT INTO transaction_logs ...', [...]);
///   return taskData;
/// });
/// ```
///
/// If an exception occurs during [operation], the transaction is rolled back
/// and the exception is rethrown.
T withTransaction<T>(Database db, T Function() operation) {
  db.execute('BEGIN TRANSACTION');
  try {
    final result = operation();
    db.execute('COMMIT');
    return result;
  } catch (e) {
    try {
      db.execute('ROLLBACK');
    } catch (rollbackError) {
      // Log rollback failure but rethrow original error
      stderr.writeln('Warning: Rollback failed: $rollbackError');
    }
    rethrow;
  }
}

/// Async version of [withTransaction] for operations that need await.
///
/// Note: Be careful with async operations inside transactions - they should
/// complete quickly to avoid holding locks for extended periods.
Future<T> withTransactionAsync<T>(
  Database db,
  Future<T> Function() operation,
) async {
  db.execute('BEGIN TRANSACTION');
  try {
    final result = await operation();
    db.execute('COMMIT');
    return result;
  } catch (e) {
    try {
      db.execute('ROLLBACK');
    } catch (rollbackError) {
      stderr.writeln('Warning: Rollback failed: $rollbackError');
    }
    rethrow;
  }
}

// =============================================================================
// Retry Logic
// =============================================================================

/// SQLite error codes that indicate transient conditions worth retrying.
///
/// Reference: https://www.sqlite.org/rescode.html
class SqliteErrorCodes {
  /// SQLITE_BUSY (5): Database file is locked
  static const int busy = 5;

  /// SQLITE_LOCKED (6): A table in the database is locked
  static const int locked = 6;

  /// SQLITE_BUSY_RECOVERY (261): WAL recovery in progress
  static const int busyRecovery = 261;

  /// SQLITE_BUSY_SNAPSHOT (517): Snapshot conflict in WAL mode
  static const int busySnapshot = 517;

  /// SQLITE_LOCKED_SHAREDCACHE (262): Shared cache lock conflict
  static const int lockedSharedCache = 262;

  /// All transient error codes that should trigger retry
  static const List<int> transient = [
    busy,
    locked,
    busyRecovery,
    busySnapshot,
    lockedSharedCache,
  ];
}

/// Configuration for retry behavior.
class RetryConfig {
  /// Maximum number of retry attempts (not including initial attempt).
  final int maxRetries;

  /// Initial delay before first retry.
  final Duration initialDelay;

  /// Maximum delay between retries.
  final Duration maxDelay;

  /// Multiplier for exponential backoff.
  final double backoffMultiplier;

  /// Whether to add jitter to delays.
  final bool addJitter;

  const RetryConfig({
    this.maxRetries = 3,
    this.initialDelay = const Duration(milliseconds: 50),
    this.maxDelay = const Duration(seconds: 2),
    this.backoffMultiplier = 2.0,
    this.addJitter = true,
  });

  /// Default configuration suitable for most use cases.
  static const defaultConfig = RetryConfig();

  /// More aggressive retry for critical operations.
  static const critical = RetryConfig(
    maxRetries: 5,
    initialDelay: Duration(milliseconds: 100),
    maxDelay: Duration(seconds: 5),
  );
}

/// Synchronous retry helper for database operations.
///
/// Uses blocking sleep() for delays. Suitable for synchronous code paths
/// where introducing async would require significant refactoring.
///
/// ```dart
/// final result = withRetrySync(db, () {
///   return db.select('SELECT * FROM tasks WHERE id = ?', [id]);
/// });
/// ```
T withRetrySync<T>(
  Database db,
  T Function() operation, {
  RetryConfig config = RetryConfig.defaultConfig,
}) {
  var attempt = 0;
  var delay = config.initialDelay;
  final random = math.Random();

  while (true) {
    try {
      return operation();
    } on SqliteException catch (e) {
      if (!isTransientError(e) || attempt >= config.maxRetries) {
        rethrow;
      }

      attempt++;
      stderr.writeln(
        'SQLite transient error (attempt $attempt/${config.maxRetries}): '
        '${e.message}. Retrying in ${delay.inMilliseconds}ms...',
      );

      // Apply jitter: ±25% of delay
      var actualDelay = delay;
      if (config.addJitter) {
        final jitter = delay.inMilliseconds * 0.25;
        final offset = (random.nextDouble() - 0.5) * 2 * jitter;
        actualDelay = Duration(
          milliseconds: delay.inMilliseconds + offset.round(),
        );
      }

      sleep(actualDelay);

      // Calculate next delay with exponential backoff
      delay = Duration(
        milliseconds: (delay.inMilliseconds * config.backoffMultiplier).round(),
      );
      if (delay > config.maxDelay) {
        delay = config.maxDelay;
      }
    }
  }
}

/// Synchronous version combining transaction and retry logic.
///
/// Wraps an atomic operation in a transaction and retries the entire
/// transaction if transient errors occur. Uses blocking sleep() for delays.
///
/// ```dart
/// final result = withRetryTransactionSync(db, () {
///   db.execute('INSERT INTO tasks ...', [...]);
///   db.execute('INSERT INTO transaction_logs ...', [...]);
///   return taskData;
/// });
/// ```
T withRetryTransactionSync<T>(
  Database db,
  T Function() operation, {
  RetryConfig config = RetryConfig.defaultConfig,
}) {
  return withRetrySync(
    db,
    () => withTransaction(db, operation),
    config: config,
  );
}

/// Async retry helper for database operations.
///
/// Uses exponential backoff with optional jitter to avoid thundering herd
/// problems when multiple processes are retrying simultaneously.
///
/// ```dart
/// final result = await withRetry(db, () {
///   return db.select('SELECT * FROM tasks WHERE id = ?', [id]);
/// });
/// ```
///
/// Only retries for transient SQLite errors (BUSY, LOCKED).
/// Non-transient errors are immediately rethrown.
Future<T> withRetry<T>(
  Database db,
  T Function() operation, {
  RetryConfig config = RetryConfig.defaultConfig,
}) async {
  var attempt = 0;
  var delay = config.initialDelay;
  final random = math.Random();

  while (true) {
    try {
      return operation();
    } on SqliteException catch (e) {
      if (!isTransientError(e) || attempt >= config.maxRetries) {
        rethrow;
      }

      attempt++;
      stderr.writeln(
        'SQLite transient error (attempt $attempt/${config.maxRetries}): '
        '${e.message}. Retrying in ${delay.inMilliseconds}ms...',
      );

      // Apply jitter: ±25% of delay
      var actualDelay = delay;
      if (config.addJitter) {
        final jitter = delay.inMilliseconds * 0.25;
        final offset = (random.nextDouble() - 0.5) * 2 * jitter;
        actualDelay = Duration(
          milliseconds: delay.inMilliseconds + offset.round(),
        );
      }

      await Future.delayed(actualDelay);

      // Calculate next delay with exponential backoff
      delay = Duration(
        milliseconds: (delay.inMilliseconds * config.backoffMultiplier).round(),
      );
      if (delay > config.maxDelay) {
        delay = config.maxDelay;
      }
    }
  }
}

/// Async version combining transaction and retry logic.
///
/// Wraps an atomic operation in a transaction and retries the entire
/// transaction if transient errors occur.
///
/// ```dart
/// final result = await withRetryTransaction(db, () {
///   db.execute('INSERT INTO tasks ...', [...]);
///   db.execute('INSERT INTO transaction_logs ...', [...]);
///   return taskData;
/// });
/// ```
Future<T> withRetryTransaction<T>(
  Database db,
  T Function() operation, {
  RetryConfig config = RetryConfig.defaultConfig,
}) async {
  return withRetry(
    db,
    () => withTransaction(db, operation),
    config: config,
  );
}

// =============================================================================
// Error Classification
// =============================================================================

/// Checks if a SQLite exception represents a transient error.
///
/// Transient errors are temporary conditions that may resolve with retry:
/// - SQLITE_BUSY: Database is locked by another process
/// - SQLITE_LOCKED: A table is locked within the same connection
bool isTransientError(SqliteException e) {
  return SqliteErrorCodes.transient.contains(e.extendedResultCode) ||
      SqliteErrorCodes.transient.contains(e.resultCode);
}

/// Checks if a SQLite exception represents a fatal error.
///
/// Fatal errors indicate problems that won't resolve with retry:
/// - Corruption, I/O errors, constraint violations, etc.
bool isFatalError(SqliteException e) {
  return !isTransientError(e);
}

/// Categories of SQLite errors for appropriate handling.
enum SqliteErrorCategory {
  /// Transient - may resolve with retry (BUSY, LOCKED)
  transient,

  /// Constraint - data validation failure (UNIQUE, FOREIGN KEY, etc.)
  constraint,

  /// Corruption - database integrity compromised
  corruption,

  /// IO - file system or disk error
  io,

  /// Schema - table/column doesn't exist
  schema,

  /// Other - unclassified error
  other,
}

/// Classifies a SQLite exception into a category for appropriate handling.
SqliteErrorCategory classifyError(SqliteException e) {
  final code = e.extendedResultCode != 0 ? e.extendedResultCode : e.resultCode;

  // Transient errors (retry-able)
  if (SqliteErrorCodes.transient.contains(code)) {
    return SqliteErrorCategory.transient;
  }

  // Constraint violations
  // SQLITE_CONSTRAINT = 19, extended: 787, 1299, 1555, 2579, etc.
  if (code == 19 || (code > 19 && code % 256 == 19)) {
    return SqliteErrorCategory.constraint;
  }

  // Corruption errors
  // SQLITE_CORRUPT = 11, SQLITE_NOTADB = 26
  if (code == 11 || code == 26 || (code > 11 && code % 256 == 11)) {
    return SqliteErrorCategory.corruption;
  }

  // I/O errors
  // SQLITE_IOERR = 10, plus many extended codes
  if (code == 10 || (code > 10 && code % 256 == 10)) {
    return SqliteErrorCategory.io;
  }

  // Schema errors
  // SQLITE_ERROR = 1 (generic, often schema-related)
  if (code == 1 && e.message.contains('no such')) {
    return SqliteErrorCategory.schema;
  }

  return SqliteErrorCategory.other;
}

/// Returns a user-friendly message for a SQLite error category.
String userFriendlyMessage(SqliteErrorCategory category, String technicalMsg) {
  switch (category) {
    case SqliteErrorCategory.transient:
      return 'Database is temporarily busy. Please try again.';
    case SqliteErrorCategory.constraint:
      return 'Operation violates data constraints: $technicalMsg';
    case SqliteErrorCategory.corruption:
      return 'Database integrity error. The database may need repair.';
    case SqliteErrorCategory.io:
      return 'Database I/O error. Check disk space and permissions.';
    case SqliteErrorCategory.schema:
      return 'Database schema error: $technicalMsg';
    case SqliteErrorCategory.other:
      return 'Database error: $technicalMsg';
  }
}
