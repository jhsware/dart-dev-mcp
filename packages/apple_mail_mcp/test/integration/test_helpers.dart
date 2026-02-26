// Shared helpers for Apple Mail MCP integration tests.
//
// Provides account discovery, result assertion, timing utilities,
// and mock classes for session-based operations.

import 'dart:async';
import 'dart:convert';

import 'package:apple_mail_mcp/apple_mail_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:test/test.dart';

/// Maximum duration for simple operations (list-accounts, get-unread-count, etc.)
const maxSimpleOpDuration = Duration(seconds: 30);

/// Maximum duration for complex operations (search, classify, etc.)
/// Some searches can take over a minute depending on mailbox size.
const maxComplexOpDuration = Duration(minutes: 3);

/// Maximum duration for batched operations that poll sessions.
const maxBatchedOpDuration = Duration(minutes: 5);

/// All inbox operation handlers keyed by operation name.
final inboxHandlers = getInboxOperations();

/// All search operation handlers keyed by operation name.
final searchHandlers = getSearchOperations();

/// All attachment operation handlers keyed by operation name.
final attachmentHandlers = getAttachmentOperations();

/// All batched operation handlers keyed by operation name.
final batchedHandlers = <String, BatchedHandler>{
  'search-emails': runBatchedSearchEmails,
  'search-email-content': runBatchedSearchEmailContent,
  'multi-search': runBatchedMultiSearch,
  'search-by-sender': runBatchedSearchBySender,
  'search-all-accounts': runBatchedSearchAllAccounts,
  'get-newsletters': runBatchedGetNewsletters,
  'classify-emails': runBatchedClassifyEmails,
  'get-email-thread': runBatchedGetEmailThread,
};

/// Runs a batched operation and waits for completion.
///
/// Creates a SessionManager + FakeRequestHandlerExtra, starts the operation
/// via [runBatchedInBackground], waits for the session to complete, and
/// returns the output wrapped in a [CallToolResult] so existing assertion
/// helpers ([assertSuccessResult], [extractText], etc.) work unchanged.
Future<CallToolResult> runBatchedOperation(
  String operation,
  Map<String, dynamic> args,
) async {
  final handler = batchedHandlers[operation];
  if (handler == null) {
    throw ArgumentError('No batched handler for operation: $operation');
  }

  final sessionManager = createTestSessionManager();
  final extra = FakeRequestHandlerExtra();

  final startResult = runBatchedInBackground(
    extra: extra,
    operation: operation,
    args: args,
    handler: handler,
    sessionManager: sessionManager,
  );

  final startParsed =
      jsonDecode(extractText(startResult)) as Map<String, dynamic>;
  final sessionId = startParsed['session_id'] as String;

  final output = await waitForSession(
    sessionId: sessionId,
    sessionManager: sessionManager,
    timeout: maxBatchedOpDuration,
  );

  return CallToolResult.fromContent([TextContent(text: output)]);
}

/// Discovers the first available Apple Mail account name.
///
/// Calls list-accounts handler (AppleScript-based) and parses the
/// "  - AccountName" lines. Falls back to filesystem-based discovery
/// via [fetchAccountNames] if AppleScript returns no accounts.
/// Throws [TestFailure] if no accounts are found by either method.
Future<String> discoverFirstAccount() async {
  // Primary: AppleScript-based discovery
  final handler = inboxHandlers['list-accounts']!;
  final result = await handler({});
  final text = extractText(result);
  // Parse "  - AccountName" lines
  final lines =
      text.split('\n').where((l) => l.trimLeft().startsWith('- ')).toList();
  if (lines.isNotEmpty) {
    return lines.first.trimLeft().substring(2).trim();
  }

  // Fallback: filesystem-based discovery
  final fsNames = await fetchAccountNames();
  if (fsNames.isNotEmpty) {
    return fsNames.first;
  }

  fail('No Apple Mail accounts found. Integration tests require at least '
      'one configured account.');
}

/// Extracts all text content from a [CallToolResult].
String extractText(CallToolResult result) {
  return result.content
      .whereType<TextContent>()
      .map((c) => c.text)
      .join('\n');
}

/// Asserts the result text does not indicate an error.
void assertSuccessResult(CallToolResult result) {
  final text = extractText(result);
  expect(text, isNot(startsWith('Error:')),
      reason: 'Result should not start with Error: got: $text');
  // Also check for the actionableError format
  expect(text, isNot(startsWith('Error: ')),
      reason: 'Result should not be an actionable error');
}

/// Asserts the result text indicates an error.
void assertErrorResult(CallToolResult result) {
  final text = extractText(result);
  expect(text.contains('Error:') || text.contains('ERROR:'), isTrue,
      reason: 'Expected an error result, got: $text');
}

/// Checks if a result contains a timeout error from AppleScript.
bool isTimeoutResult(CallToolResult result) {
  final text = extractText(result);
  return text.contains('timed out');
}

/// Runs an async operation and returns (result, elapsed duration).
Future<(T, Duration)> timeOperation<T>(Future<T> Function() fn) async {
  final sw = Stopwatch()..start();
  final result = await fn();
  sw.stop();
  return (result, sw.elapsed);
}

/// Like [timeOperation] but catches exceptions (e.g. AppleScript timeouts)
/// and returns null instead ALONG with the exception message.
///
/// Some handlers don't catch the AppleScript timeout exception internally,
/// so it propagates as an unhandled Exception. This wrapper lets tests
/// treat such timeouts as an acceptable outcome.
Future<(CallToolResult?, Duration, String?)>
    timeOperationTolerant(Future<CallToolResult> Function() fn) async {
  final sw = Stopwatch()..start();
  try {
    final result = await fn();
    sw.stop();
    return (result, sw.elapsed, null);
  } on Exception catch (e) {
    sw.stop();
    return (null, sw.elapsed, e.toString());
  }
}

/// A minimal fake for [RequestHandlerExtra] that records progress calls.
///
/// Used for testing batched operations that require sending progress
/// notifications.
class FakeRequestHandlerExtra implements RequestHandlerExtra {
  final List<({double progress, String? message})> progressCalls = [];

  @override
  Future<void> sendProgress(double progress,
      {String? message, double? total}) async {
    progressCalls.add((progress: progress, message: message));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    // Ignore other methods that may be called
    return null;
  }
}

/// Creates a fresh [SessionManager] for testing.
///
/// Note: SessionManager is a singleton, but for tests we can still
/// use it since sessions are identified by unique IDs.
SessionManager createTestSessionManager() {
  return SessionManager();
}
/// Checks Full Disk Access and prints a warning if not granted.
///
/// Call this in setUpAll() so the test output clearly explains why
/// mdfind-based operations return 0 results.
Future<void> checkFullDiskAccessOrWarn() async {
  final fdaStatus = await checkFullDiskAccess();
  if (fdaStatus == false) {
    // ignore: avoid_print
    print('\n'
        '╔══════════════════════════════════════════════════════════════╗\n'
        '║  WARNING: Full Disk Access is NOT granted.                  ║\n'
        '║                                                             ║\n'
        '║  Spotlight (mdfind) operations will return 0 results.       ║\n'
        '║  Tests will pass but with empty data.                       ║\n'
        '║                                                             ║\n'
        '║  To test with real data, grant Full Disk Access to your     ║\n'
        '║  terminal/IDE in:                                           ║\n'
        '║  System Settings > Privacy & Security > Full Disk Access    ║\n'
        '╚══════════════════════════════════════════════════════════════╝\n');
  } else if (fdaStatus == true) {
    // ignore: avoid_print
    print('✓ Full Disk Access is granted — mdfind operations will work.');
  } else {
    // ignore: avoid_print
    print('⚠ Could not determine Full Disk Access status '
        '(~/Library/Mail may not exist).');
  }
}

/// Waits for a session to complete by polling.
///
/// Returns the final output text from all chunks.
Future<String> waitForSession({
  required String sessionId,
  required SessionManager sessionManager,
  Duration pollInterval = const Duration(milliseconds: 100),
  Duration timeout = const Duration(minutes: 4),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final session = sessionManager.getSession(sessionId);
    if (session == null) {
      fail('Session $sessionId not found');
    }
    if (session.isComplete) {
      return session.chunks.join('');
    }
    await Future<void>.delayed(pollInterval);
  }
  fail('Session $sessionId did not complete within $timeout');
}