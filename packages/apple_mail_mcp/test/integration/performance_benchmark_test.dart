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

  group('performance benchmarks', () {
    test('list-accounts benchmark (3 runs)', () async {
      final durations = <Duration>[];

      for (var i = 0; i < 3; i++) {
        final (_, elapsed) = await timeOperation(
          () => inboxHandlers['list-accounts']!({}),
        );
        durations.add(elapsed);
      }

      final avgMs =
          durations.map((d) => d.inMilliseconds).reduce((a, b) => a + b) /
              durations.length;
      // ignore: avoid_print
      print('list-accounts avg: ${avgMs.toStringAsFixed(0)}ms '
          '(${durations.map((d) => '${d.inMilliseconds}ms').join(', ')})');

      for (final d in durations) {
        expect(d, lessThan(maxSimpleOpDuration),
            reason: 'Each run should complete within time limit');
      }
    });

    test('get-unread-count benchmark (3 runs)', () async {
      final durations = <Duration>[];

      for (var i = 0; i < 3; i++) {
        final (_, elapsed) = await timeOperation(
          () => inboxHandlers['get-unread-count']!({}),
        );
        durations.add(elapsed);
      }

      final avgMs =
          durations.map((d) => d.inMilliseconds).reduce((a, b) => a + b) /
              durations.length;
      // ignore: avoid_print
      print('get-unread-count avg: ${avgMs.toStringAsFixed(0)}ms '
          '(${durations.map((d) => '${d.inMilliseconds}ms').join(', ')})');

      for (final d in durations) {
        expect(d, lessThan(maxSimpleOpDuration));
      }
    });

    test('list-emails benchmark (3 runs, 10 emails)', () async {
      final durations = <Duration>[];

      for (var i = 0; i < 3; i++) {
        final (_, elapsed) = await timeOperation(
          () => inboxHandlers['list-emails']!({
            'account': account,
            'limit': 10,
          }),
        );
        durations.add(elapsed);
      }

      final avgMs =
          durations.map((d) => d.inMilliseconds).reduce((a, b) => a + b) /
              durations.length;
      // ignore: avoid_print
      print('list-emails (10) avg: ${avgMs.toStringAsFixed(0)}ms '
          '(${durations.map((d) => '${d.inMilliseconds}ms').join(', ')})');

      for (final d in durations) {
        expect(d, lessThan(maxSimpleOpDuration));
      }
    });

    test('search-emails benchmark (3 runs)', () async {
      final durations = <Duration>[];

      for (var i = 0; i < 3; i++) {
        final (_, elapsed) = await timeOperation(
          () => runBatchedOperation('search-emails', {
            'account': account,
            'query': 'the',
            'max_results': 10,
          }),
        );
        durations.add(elapsed);
      }

      final avgMs =
          durations.map((d) => d.inMilliseconds).reduce((a, b) => a + b) /
              durations.length;
      // ignore: avoid_print
      print('search-emails avg: ${avgMs.toStringAsFixed(0)}ms '
          '(${durations.map((d) => '${d.inMilliseconds}ms').join(', ')})');

      for (final d in durations) {
        expect(d, lessThan(maxBatchedOpDuration));
      }
    });

    test('classify-emails benchmark — BM25 timing (3 runs)', () async {
      final classifiers = jsonEncode({
        'common': ['the', 'and'],
        'greetings': ['hello', 'hi'],
        'actions': ['from', 'to'],
      });

      final durations = <Duration>[];

      for (var i = 0; i < 3; i++) {
        final (_, elapsed) = await timeOperation(
          () => runBatchedOperation('classify-emails', {
            'account': account,
            'classifiers': classifiers,
            'days_back': 30,
            'max_results': 50,
          }),
        );
        durations.add(elapsed);
      }

      final avgMs =
          durations.map((d) => d.inMilliseconds).reduce((a, b) => a + b) /
              durations.length;
      // ignore: avoid_print
      print('classify-emails (3 cats, 50 emails) avg: '
          '${avgMs.toStringAsFixed(0)}ms '
          '(${durations.map((d) => '${d.inMilliseconds}ms').join(', ')})');

      for (final d in durations) {
        expect(d, lessThan(maxBatchedOpDuration));
      }
    });

    test('classify-emails scaling — 1 vs 3 vs 5 categories', () async {
      final configs = <int, String>{
        1: jsonEncode({'cat_a': ['the', 'and']}),
        3: jsonEncode({
          'cat_a': ['the', 'and'],
          'cat_b': ['from', 'to'],
          'cat_c': ['hello', 'hi'],
        }),
        5: jsonEncode({
          'cat_a': ['the', 'and'],
          'cat_b': ['from', 'to'],
          'cat_c': ['hello', 'hi'],
          'cat_d': ['new', 'update'],
          'cat_e': ['re', 'fwd'],
        }),
      };

      final timings = <int, Duration>{};

      for (final entry in configs.entries) {
        final (_, elapsed) = await timeOperation(
          () => runBatchedOperation('classify-emails', {
            'account': account,
            'classifiers': entry.value,
            'days_back': 30,
            'max_results': 50,
          }),
        );
        timings[entry.key] = elapsed;
      }

      // ignore: avoid_print
      print('classify-emails category scaling:');
      for (final entry in timings.entries) {
        // ignore: avoid_print
        print('  ${entry.key} categories: ${entry.value.inMilliseconds}ms');
      }

      // All should complete within the batched op limit
      for (final d in timings.values) {
        expect(d, lessThan(maxBatchedOpDuration));
      }
    });

    test('batched search-emails session lifecycle benchmark', () async {
      final sessionManager = createTestSessionManager();
      final extra = FakeRequestHandlerExtra();

      final sw = Stopwatch()..start();

      final startResult = runBatchedInBackground(
        extra: extra,
        operation: 'search-emails',
        args: {
          'account': account,
          'query': 'the',
          'max_results': 10,
        },
        handler: runBatchedSearchEmails,
        sessionManager: sessionManager,
      );

      final startParsed =
          jsonDecode(extractText(startResult)) as Map<String, dynamic>;
      final sessionId = startParsed['session_id'] as String;

      final startElapsed = sw.elapsed;
      // ignore: avoid_print
      print('Batched start returned in: ${startElapsed.inMilliseconds}ms');

      await waitForSession(
        sessionId: sessionId,
        sessionManager: sessionManager,
        timeout: maxBatchedOpDuration,
      );

      sw.stop();
      final totalElapsed = sw.elapsed;
      // ignore: avoid_print
      print('Batched total time: ${totalElapsed.inMilliseconds}ms');

      expect(startElapsed, lessThan(const Duration(seconds: 2)),
          reason: 'Start should be near-instant');
      expect(totalElapsed, lessThan(maxBatchedOpDuration),
          reason: 'Total should complete within batched limit');
    });

    test('get-inbox-overview benchmark (3 runs)', () async {
      final durations = <Duration>[];

      for (var i = 0; i < 3; i++) {
        final (_, elapsed) = await timeOperation(
          () => inboxHandlers['get-inbox-overview']!({}),
        );
        durations.add(elapsed);
      }

      final avgMs =
          durations.map((d) => d.inMilliseconds).reduce((a, b) => a + b) /
              durations.length;
      // ignore: avoid_print
      print('get-inbox-overview avg: ${avgMs.toStringAsFixed(0)}ms '
          '(${durations.map((d) => '${d.inMilliseconds}ms').join(', ')})');

      for (final d in durations) {
        expect(d, lessThan(maxComplexOpDuration));
      }
    });
  });
}
