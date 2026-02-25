@Tags(['integration'])
@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';

import 'package:apple_mail_mcp/apple_mail_mcp.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late String account;

  setUpAll(() async {
    account = await discoverFirstAccount();
  });

  group('session lifecycle', () {
    test('batched search-emails creates and completes a session', () async {
      final sessionManager = createTestSessionManager();
      final extra = FakeRequestHandlerExtra();

      // Start a batched search operation
      final (startResult, startElapsed) = await timeOperation(
        () async => runBatchedInBackground(
          extra: extra,
          operation: 'search-emails',
          args: {
            'account': account,
            'query': 'the',
            'max_results': 5,
          },
          handler: runBatchedSearchEmails,
          sessionManager: sessionManager,
        ),
      );

      // Should return immediately with session_id
      final startText = extractText(startResult);
      final startParsed = jsonDecode(startText) as Map<String, dynamic>;
      expect(startParsed, contains('session_id'));
      expect(startParsed['status'], equals('running'));
      expect(startElapsed, lessThan(const Duration(seconds: 2)),
          reason: 'Batched start should return immediately');

      final sessionId = startParsed['session_id'] as String;

      // Wait for session to complete
      final output = await waitForSession(
        sessionId: sessionId,
        sessionManager: sessionManager,
        timeout: maxBatchedOpDuration,
      );

      expect(output, isNotEmpty, reason: 'Session should produce output');

      // Test get_output handler
      final getOutputResult = handleGetOutput(
        {'session_id': sessionId, 'chunk_index': 0},
        sessionManager,
      );
      final getOutputText = extractText(getOutputResult);
      final getOutputParsed =
          jsonDecode(getOutputText) as Map<String, dynamic>;
      expect(getOutputParsed['is_complete'], isTrue);
      expect(getOutputParsed['session_id'], equals(sessionId));
    });

    test('list_sessions returns active sessions', () async {
      final sessionManager = createTestSessionManager();

      final listResult = handleListSessions(sessionManager);
      final listText = extractText(listResult);
      final listParsed = jsonDecode(listText) as Map<String, dynamic>;

      expect(listParsed, contains('sessions'));
      expect(listParsed, contains('total'));
      expect(listParsed['sessions'], isA<List>());
    });

    test('cancel non-existent session returns error', () async {
      final sessionManager = createTestSessionManager();

      final cancelResult = await handleCancelSession(
        {'session_id': 'nonexistent-session-id'},
        sessionManager,
      );

      final cancelText = extractText(cancelResult);
      expect(cancelText.contains('not found') || cancelText.contains('Not found'),
          isTrue,
          reason: 'Should indicate session not found');
    });

    test('get_output for non-existent session returns error', () async {
      final sessionManager = createTestSessionManager();

      final result = handleGetOutput(
        {'session_id': 'nonexistent-session-id'},
        sessionManager,
      );

      final text = extractText(result);
      expect(text.contains('not found') || text.contains('Not found'), isTrue,
          reason: 'Should indicate session not found');
    });

    test('batched classify-emails creates session and completes', () async {
      final sessionManager = createTestSessionManager();
      final extra = FakeRequestHandlerExtra();

      final classifiers = jsonEncode({
        'test_cat': ['the', 'and'],
      });

      final startResult = runBatchedInBackground(
        extra: extra,
        operation: 'classify-emails',
        args: {
          'account': account,
          'classifiers': classifiers,
          'days_back': 7,
          'max_results': 20,
        },
        handler: runBatchedClassifyEmails,
        sessionManager: sessionManager,
      );

      final startText = extractText(startResult);
      final startParsed = jsonDecode(startText) as Map<String, dynamic>;
      expect(startParsed, contains('session_id'));

      final sessionId = startParsed['session_id'] as String;

      // Wait for completion
      final output = await waitForSession(
        sessionId: sessionId,
        sessionManager: sessionManager,
        timeout: maxBatchedOpDuration,
      );

      expect(output, isNotEmpty);

      // Verify progress was reported
      expect(extra.progressCalls, isNotEmpty,
          reason: 'Batched handler should send progress notifications');
    });

    test('session polling with chunk_index pagination works', () async {
      final sessionManager = createTestSessionManager();
      final extra = FakeRequestHandlerExtra();

      final startResult = runBatchedInBackground(
        extra: extra,
        operation: 'search-emails',
        args: {
          'account': account,
          'query': 'the',
          'max_results': 5,
        },
        handler: runBatchedSearchEmails,
        sessionManager: sessionManager,
      );

      final startParsed =
          jsonDecode(extractText(startResult)) as Map<String, dynamic>;
      final sessionId = startParsed['session_id'] as String;

      await waitForSession(
        sessionId: sessionId,
        sessionManager: sessionManager,
        timeout: maxBatchedOpDuration,
      );

      // Poll with chunk_index=0, max_chunks=1
      final pollResult = handleGetOutput(
        {'session_id': sessionId, 'chunk_index': 0, 'max_chunks': 1},
        sessionManager,
      );

      final pollParsed =
          jsonDecode(extractText(pollResult)) as Map<String, dynamic>;
      expect(pollParsed, contains('chunk_index'));
      expect(pollParsed, contains('chunks_returned'));
      expect(pollParsed, contains('has_more_chunks'));
      expect(pollParsed, contains('total_chunks'));
    });

    test('batched get-email-thread creates session and completes', () async {

      final sessionManager = createTestSessionManager();
      final extra = FakeRequestHandlerExtra();

      final (startResult, startElapsed) = await timeOperation(
        () async => runBatchedInBackground(
          extra: extra,
          operation: 'get-email-thread',
          args: {
            'account': account,
            'subject_keyword': 'the',
          },
          handler: runBatchedGetEmailThread,
          sessionManager: sessionManager,
        ),
      );

      final startText = extractText(startResult);
      final startParsed = jsonDecode(startText) as Map<String, dynamic>;
      expect(startParsed, contains('session_id'));
      expect(startParsed['status'], equals('running'));
      expect(startElapsed, lessThan(const Duration(seconds: 2)),
          reason: 'Batched start should return immediately');

      final sessionId = startParsed['session_id'] as String;

      final output = await waitForSession(
        sessionId: sessionId,
        sessionManager: sessionManager,
        timeout: maxBatchedOpDuration,
      );

      expect(output, isNotEmpty, reason: 'Session should produce output');

      final getOutputResult = handleGetOutput(
        {'session_id': sessionId, 'chunk_index': 0},
        sessionManager,
      );
      final getOutputText = extractText(getOutputResult);
      final getOutputParsed =
          jsonDecode(getOutputText) as Map<String, dynamic>;
      expect(getOutputParsed['is_complete'], isTrue);
    });
    });
}
