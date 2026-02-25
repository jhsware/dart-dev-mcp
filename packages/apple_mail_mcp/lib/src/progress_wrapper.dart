// Progress wrapper for long-running Apple Mail operations.
//
// Provides fire-and-forget background execution with session tracking
// and MCP progress notifications. Returns session_id immediately,
// runs the handler in a background Future that the client polls via get_output.
//
// Two dispatch modes:
// 1. `runInBackground` — wraps a standard handler (args → CallToolResult)
// 2. `runBatchedInBackground` — wraps a batched handler that writes
//    progressive chunks directly to the session

import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

/// Type alias for batched handlers that manage their own session output.
///
/// Unlike standard handlers, batched handlers receive the session and extra
/// objects directly so they can write progressive chunks and send progress
/// notifications between batches.
typedef BatchedHandler = Future<void> Function({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
});

/// Set of operation names considered "slow" (potentially long-running).
/// These are dispatched via [runInBackground] for fire-and-forget execution.
const slowOperations = {
  'get-statistics',
  'export-emails',
  'save-email-attachment',
};

/// Set of operation names that use batched execution.
const batchedOperations = {
  'search-email-content',
  'search-emails',
  'multi-search',
  'search-by-sender',
  'search-all-accounts',
  'get-newsletters',
  'classify-emails',
  'get-email-thread',

  'list-email-attachments',
};

/// Runs a handler in the background and returns a session_id immediately.
/// 1. Creates a session via SessionManager
/// 2. Returns immediately with JSON containing session_id + status
/// 3. In a background Future:
///    a. Sends a progress notification ("Running operation...")
///    b. Calls the original handler
///    c. Stores the result text in the session
///    d. Sends a completion progress notification
///    e. On error: stores error in session, sends failure progress
CallToolResult runInBackground({
  required RequestHandlerExtra extra,
  required String operation,
  required Map<String, dynamic> args,
  required Future<CallToolResult> Function(Map<String, dynamic>) handler,
  required SessionManager sessionManager,
}) {
  final sessionId = sessionManager.createSession(operation, operation);
  final session = sessionManager.getSession(sessionId)!;

  // Fire-and-forget: run handler in background
  unawaited(() async {
    try {
      await extra.sendProgress(0, message: 'Running $operation...');

      final result = await handler(args);

      // Extract text content from the result and store in session
      final textContent = result.content
          .whereType<TextContent>()
          .map((c) => c.text)
          .join('\n');
      session.chunks.add(textContent);
      session.isComplete = true;

      await extra.sendProgress(1, message: '$operation completed');
    } catch (e) {
      session.chunks.add('ERROR: $e');
      session.isComplete = true;
      await extra.sendProgress(1, message: '$operation failed: $e');
    }
  }());

  // Return immediately with session_id
  return CallToolResult.fromContent([
    TextContent(
      text: jsonEncode({
        'session_id': sessionId,
        'status': 'running',
        'message':
            'Operation started. Use get_output with this session_id to poll for results.',
      }),
    ),
  ]);
}

/// Runs a batched handler in the background and returns a session_id immediately.
///
/// Unlike [runInBackground], the batched handler is responsible for writing
/// chunks to the session and marking it complete. This enables progressive
/// output that clients can poll via get_output between batches.
CallToolResult runBatchedInBackground({
  required RequestHandlerExtra extra,
  required String operation,
  required Map<String, dynamic> args,
  required BatchedHandler handler,
  required SessionManager sessionManager,
}) {
  final sessionId = sessionManager.createSession(operation, operation);
  final session = sessionManager.getSession(sessionId)!;

  // Fire-and-forget: run batched handler in background
  unawaited(() async {
    try {
      await handler(args: args, session: session, extra: extra);
      // Handler is responsible for setting session.isComplete = true
      // but ensure it's set even if the handler forgets
      if (!session.isComplete) {
        session.isComplete = true;
      }
    } catch (e) {
      session.chunks.add('ERROR: $e');
      session.isComplete = true;
      await extra.sendProgress(1, message: '$operation failed: $e');
    }
  }());

  // Return immediately with session_id
  return CallToolResult.fromContent([
    TextContent(
      text: jsonEncode({
        'session_id': sessionId,
        'status': 'running',
        'message':
            'Operation started. Use get_output with this session_id to poll for results.',
      }),
    ),
  ]);
}
