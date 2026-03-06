/// Transaction log repository for database operations.
///
/// Provides CRUD operations for transaction log entries, with optimized
/// queries for both timeline views (fast) and detailed audit trails.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'transaction_log.dart';

/// Repository for managing transaction log entries in SQLite.
class TransactionLogRepository {
  final Database db;
  final _uuid = const Uuid();

  TransactionLogRepository(this.db);

  /// Initialize the transaction_logs table and indexes.
  ///
  /// Should be called during database initialization.
  void initializeTable() {
    // Create the transaction_logs table
    db.execute('''
      CREATE TABLE IF NOT EXISTS transaction_logs (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        transaction_type TEXT NOT NULL,
        summary TEXT NOT NULL,
        changes TEXT,
        project_id TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // Index for timeline queries (sorted by timestamp)
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_transaction_logs_created_at 
      ON transaction_logs(created_at DESC)
    ''');

    // Index for entity-specific audit queries
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_transaction_logs_entity 
      ON transaction_logs(entity_type, entity_id)
    ''');

    // Index for project-filtered queries
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_transaction_logs_project 
      ON transaction_logs(project_id)
    ''');

    // Composite index for project + time queries
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_transaction_logs_project_time 
      ON transaction_logs(project_id, created_at DESC)
    ''');
  }

  /// Log a new transaction.
  ///
  /// Returns the created log entry with generated ID and timestamp.
  TransactionLogEntry log({
    required EntityType entityType,
    required String entityId,
    required TransactionType transactionType,
    required String summary,
    Map<String, dynamic>? changes,
    String? projectId,
  }) {
    final id = _uuid.v4();
    final now = DateTime.now().toUtc();
    final timestamp = now.toIso8601String();
    final changesJson = changes != null ? jsonEncode(changes) : null;

    db.execute('''
      INSERT INTO transaction_logs 
        (id, entity_type, entity_id, transaction_type, summary, changes, project_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      id,
      entityType.toDbValue(),
      entityId,
      transactionType.toDbValue(),
      summary,
      changesJson,
      projectId,
      timestamp,
    ]);

    return TransactionLogEntry(
      id: id,
      timestamp: now,
      entityType: entityType,
      entityId: entityId,
      transactionType: transactionType,
      summary: summary,
      changes: changes,
      projectId: projectId,
    );
  }

  /// Get timeline entries for quick viewing.
  ///
  /// Returns entries in reverse chronological order by default.
  /// Uses the summary field for fast display without parsing changes JSON.
  List<TransactionLogEntry> getTimeline(TransactionLogQuery query) {
    final conditions = <String>[];
    final values = <Object?>[];

    if (query.entityType != null) {
      conditions.add('entity_type = ?');
      values.add(query.entityType!.toDbValue());
    }

    if (query.entityId != null) {
      conditions.add('entity_id = ?');
      values.add(query.entityId);
    }

    if (query.transactionType != null) {
      conditions.add('transaction_type = ?');
      values.add(query.transactionType!.toDbValue());
    }



    if (query.after != null) {
      conditions.add('created_at > ?');
      values.add(query.after!.toUtc().toIso8601String());
    }

    if (query.before != null) {
      conditions.add('created_at < ?');
      values.add(query.before!.toUtc().toIso8601String());
    }

    final whereClause = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final orderDirection = query.newestFirst ? 'DESC' : 'ASC';

    // For timeline, we select all fields but the caller can choose to
    // use toTimelineJson() to exclude changes from the output
    final sql = '''
      SELECT id, entity_type, entity_id, transaction_type, summary, changes, project_id, created_at
      FROM transaction_logs
      $whereClause
      ORDER BY created_at $orderDirection
      LIMIT ? OFFSET ?
    ''';

    values.add(query.limit);
    values.add(query.offset);

    final result = db.select(sql, values);
    return result.map((row) => TransactionLogEntry.fromRow(row)).toList();
  }

  /// Get audit trail for a specific entity.
  ///
  /// Returns all transactions for the given entity type and ID,
  /// including full change details for compliance and debugging.
  List<TransactionLogEntry> getAuditTrail({
    required EntityType entityType,
    required String entityId,
    int limit = 100,
    int offset = 0,
    bool newestFirst = true,
  }) {
    final orderDirection = newestFirst ? 'DESC' : 'ASC';

    final result = db.select('''
      SELECT id, entity_type, entity_id, transaction_type, summary, changes, project_id, created_at
      FROM transaction_logs
      WHERE entity_type = ? AND entity_id = ?
      ORDER BY created_at $orderDirection
      LIMIT ? OFFSET ?
    ''', [entityType.toDbValue(), entityId, limit, offset]);

    return result.map((row) => TransactionLogEntry.fromRow(row)).toList();
  }

  /// Get count of transaction log entries matching the query.
  int count(TransactionLogQuery query) {
    final conditions = <String>[];
    final values = <Object?>[];

    if (query.entityType != null) {
      conditions.add('entity_type = ?');
      values.add(query.entityType!.toDbValue());
    }

    if (query.entityId != null) {
      conditions.add('entity_id = ?');
      values.add(query.entityId);
    }

    if (query.transactionType != null) {
      conditions.add('transaction_type = ?');
      values.add(query.transactionType!.toDbValue());
    }



    if (query.after != null) {
      conditions.add('created_at > ?');
      values.add(query.after!.toUtc().toIso8601String());
    }

    if (query.before != null) {
      conditions.add('created_at < ?');
      values.add(query.before!.toUtc().toIso8601String());
    }

    final whereClause = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final result = db.select('SELECT COUNT(*) as count FROM transaction_logs $whereClause', values);
    return result.first['count'] as int;
  }

  /// Delete old transaction log entries.
  ///
  /// Useful for maintenance and keeping database size manageable.
  int deleteOlderThan(DateTime cutoff) {
    final timestamp = cutoff.toUtc().toIso8601String();
    db.execute('DELETE FROM transaction_logs WHERE created_at < ?', [timestamp]);
    return db.updatedRows;
  }
}
