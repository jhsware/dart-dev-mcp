// Progress wrapper for long-running Apple Mail operations.
//
// Provides fire-and-forget background execution with session tracking
// and MCP progress notifications. Returns session_id immediately,
// runs the handler in a background Future that the client polls via get_output.

import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

/// Set of operation names considered "slow" (potentially long-running).
const slowOperations = {
  'search-email-content',
  'classify-emails',
  'search-all-accounts',
  'get-newsletters',
  'get-statistics',
  'export-emails',
  'multi-search',
  'search-emails',
  'search-by-sender',
};

/// Runs a handler in the background and returns a session_id immediately.
///
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