// Session management operations for Apple Mail MCP.
//
// Provides get_output, list_sessions, and cancel operations for polling
// long-running operations. Mirrors the dart_runner session pattern.

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

/// Get output chunks from a session.
CallToolResult handleGetOutput(
  Map<String, dynamic> args,
  SessionManager sessionManager,
) {
  final sessionId = args['session_id'] as String?;
  if (requireString(sessionId, 'session_id') case final error?) return error;

  final chunkIndex = (args['chunk_index'] as num?)?.toInt() ?? 0;
  final maxChunks =
      ((args['max_chunks'] as num?)?.toInt() ?? 50).clamp(1, 200);

  final session = sessionManager.getSession(sessionId!);
  if (session == null) return notFoundError('Session', sessionId);

  final totalChunks = session.chunks.length;
  final startIndex = chunkIndex.clamp(0, totalChunks);
  final endIndex = (startIndex + maxChunks).clamp(0, totalChunks);
  final chunks = startIndex < totalChunks
      ? session.chunks.sublist(startIndex, endIndex)
      : <String>[];
  final hasMoreChunks = endIndex < totalChunks;
  final nextChunkIndex = hasMoreChunks ? endIndex : null;

  final response = <String, dynamic>{
    'session_id': sessionId,
    'operation': session.operation,
    'is_complete': session.isComplete,
    'total_chunks': totalChunks,
    'chunk_index': startIndex,
    'chunks_returned': chunks.length,
    'has_more_chunks': hasMoreChunks || !session.isComplete,
    'next_chunk_index': nextChunkIndex,
    'output': chunks.join(''),
  };

  if (!session.isComplete && !hasMoreChunks) {
    response['message'] =
        'Operation still running. Poll again with the same chunk_index.';
  } else if (hasMoreChunks) {
    response['message'] =
        'More chunks available. Call get_output with chunk_index: $nextChunkIndex';
  } else if (session.isComplete && !hasMoreChunks) {
    response['message'] = 'All output retrieved. Operation complete.';
  }

  return textResult(jsonEncode(response));
}

/// List all sessions.
CallToolResult handleListSessions(SessionManager sessionManager) {
  sessionManager.cleanupOldSessions();

  final sessions = sessionManager.allSessions
      .map((s) => {
            'session_id': s.id,
            'operation': s.operation,
            'is_complete': s.isComplete,
            'chunks_collected': s.chunks.length,
            'started_at': s.startedAt.toIso8601String(),
          })
      .toList();

  return textResult(jsonEncode({
    'sessions': sessions,
    'total': sessions.length,
  }));
}

/// Cancel a running session.
Future<CallToolResult> handleCancelSession(
  Map<String, dynamic> args,
  SessionManager sessionManager,
) async {
  final sessionId = args['session_id'] as String?;
  if (requireString(sessionId, 'session_id') case final error?) return error;

  final session = sessionManager.getSession(sessionId!);
  if (session == null) return notFoundError('Session', sessionId);

  await sessionManager.removeSession(sessionId);

  return textResult(jsonEncode({
    'status': 'cancelled',
    'session_id': sessionId,
    'message': 'Session cancelled and removed.',
  }));
}
