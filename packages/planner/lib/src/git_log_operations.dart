import 'dart:math';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart';

import 'planner.dart';

/// Git log operations handler.
///
/// Provides operations to log git commits and merges to the transaction log,
/// enabling the timeline viewer to display git activity alongside task/step
/// activity.
class GitLogOperations {
  final Database database;
  final TransactionLogRepository transactionLogRepository;

  GitLogOperations({
    required this.database,
    required this.transactionLogRepository,
  });

  /// Log a git commit to the transaction log.
  ///
  /// Records a commit hash, branch name, and optional step/message so that
  /// git activity appears in the timeline viewer alongside task/step activity.
  CallToolResult logCommit(Map<String, dynamic>? args) {
    final commitHash = args?['commit_hash'] as String?;
    final branch = args?['branch'] as String?;
    final taskId = args?['task_id'] as String?;
    final stepId = args?['step_id'] as String?;
    final message = args?['message'] as String?;

    if (requireString(commitHash, 'commit_hash') case final error?) {
      return error;
    }
    if (requireString(branch, 'branch') case final error?) {
      return error;
    }
    if (requireString(taskId, 'task_id') case final error?) {
      return error;
    }

    // Look up task for title and project_id
    final taskResult = database.select(
        'SELECT id, title, project_id FROM tasks WHERE id = ?', [taskId]);
    if (taskResult.isEmpty) {
      return notFoundError('Task', taskId!);
    }

    final taskInfo = taskResult.first;
    final taskTitle = taskInfo['title'] as String;
    final projectId = taskInfo['project_id'] as String?;
    final shortHash =
        commitHash!.substring(0, min(7, commitHash.length));

    final entry = transactionLogRepository.log(
      entityType: EntityType.task,
      entityId: taskId!,
      transactionType: TransactionType.update,
      summary:
          "Git commit $shortHash on branch '$branch' for task '$taskTitle'",
      changes: {
        'after': {
          'commit_hash': commitHash,
          'branch': branch,
          ?'step_id': stepId,
          ?'message': message,
          'type': 'commit',
        },
      },
      projectId: projectId,
    );

    return jsonResult({
      'success': true,
      'message': 'Git commit logged',
      'log_entry_id': entry.id,
    });
  }

  /// Log a git merge to the transaction log.
  ///
  /// Records a merge commit hash with source and target branches so that
  /// git activity appears in the timeline viewer alongside task/step activity.
  CallToolResult logMerge(Map<String, dynamic>? args) {
    final commitHash = args?['commit_hash'] as String?;
    final sourceBranch = args?['source_branch'] as String?;
    final targetBranch = args?['target_branch'] as String?;
    final taskId = args?['task_id'] as String?;

    if (requireString(commitHash, 'commit_hash') case final error?) {
      return error;
    }
    if (requireString(sourceBranch, 'source_branch') case final error?) {
      return error;
    }
    if (requireString(targetBranch, 'target_branch') case final error?) {
      return error;
    }
    if (requireString(taskId, 'task_id') case final error?) {
      return error;
    }

    // Look up task for title and project_id
    final taskResult = database.select(
        'SELECT id, title, project_id FROM tasks WHERE id = ?', [taskId]);
    if (taskResult.isEmpty) {
      return notFoundError('Task', taskId!);
    }

    final taskInfo = taskResult.first;
    final taskTitle = taskInfo['title'] as String;
    final projectId = taskInfo['project_id'] as String?;
    final shortHash =
        commitHash!.substring(0, min(7, commitHash.length));

    final entry = transactionLogRepository.log(
      entityType: EntityType.task,
      entityId: taskId!,
      transactionType: TransactionType.update,
      summary:
          "Merged branch '$sourceBranch' into '$targetBranch' (commit $shortHash) for task '$taskTitle'",
      changes: {
        'after': {
          'commit_hash': commitHash,
          'source_branch': sourceBranch,
          'target_branch': targetBranch,
          'type': 'merge',
        },
      },
      projectId: projectId,
    );

    return jsonResult({
      'success': true,
      'message': 'Git merge logged',
      'log_entry_id': entry.id,
    });
  }
}
