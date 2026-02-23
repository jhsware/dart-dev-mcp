// Progress wrapper for long-running Apple Mail operations.
//
// Wraps existing handlers with session tracking and MCP progress
// notifications without modifying their signatures.

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

/// Wraps a handler to add progress notifications and session tracking.
///
/// 1. Creates a session via SessionManager
/// 2. Sends a progress notification ("Running operation...")
/// 3. Calls the original handler
/// 4. Stores the result text in the session
/// 5. Sends a completion progress notification
/// 6. Returns the original result
Future<CallToolResult> runWithProgress({
  required RequestHandlerExtra extra,
  required String operation,
  required Map<String, dynamic> args,
  required Future<CallToolResult> Function(Map<String, dynamic>) handler,
  required SessionManager sessionManager,
}) async {
  final sessionId = sessionManager.createSession(operation, operation);
  final session = sessionManager.getSession(sessionId)!;

  // Send "started" progress
  await extra.sendProgress(0, message: 'Running $operation...');

  try {
    final result = await handler(args);

    // Extract text content from the result and store in session
    final textContent = result.content
        .whereType<TextContent>()
        .map((c) => c.text)
        .join('\n');
    session.chunks.add(textContent);
    session.isComplete = true;

    // Send "completed" progress
    await extra.sendProgress(1, message: '$operation completed');

    return result;
  } catch (e) {
    session.chunks.add('ERROR: $e');
    session.isComplete = true;
    await extra.sendProgress(1, message: '$operation failed: $e');
    rethrow;
  }
}
