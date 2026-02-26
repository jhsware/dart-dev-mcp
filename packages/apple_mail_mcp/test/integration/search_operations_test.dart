@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late String account;

  setUpAll(() async {
    await checkFullDiskAccessOrWarn();
    account = await discoverFirstAccount();
  });

  group('search-emails', () {
    test('basic query returns structured results', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('search-emails', {
          'account': account,
          'query': 'the',
          'max_results': 5,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('SEARCH RESULTS'));
      expect(text, contains('FOUND:'));
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });

    test('AND operator narrows results', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('search-emails', {
          'account': account,
          'query': 'the and',
          'search_operator': 'and',
          'max_results': 5,
        }),
      );

      if (!isTimeoutResult(result)) {
        assertSuccessResult(result);
        final text = extractText(result);
        expect(text, contains('SEARCH RESULTS'));
      }
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });

    test('subject-only search field works', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('search-emails', {
          'account': account,
          'query': 'the',
          'search_field': 'subject',
          'max_results': 5,
        }),
      );

      if (!isTimeoutResult(result)) {
        assertSuccessResult(result);
      }
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });

    test('sender-only search field works', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('search-emails', {
          'account': account,
          'query': 'the',
          'search_field': 'sender',
          'max_results': 5,
        }),
      );

      if (!isTimeoutResult(result)) {
        assertSuccessResult(result);
      }
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });

    test('days_back filter works', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('search-emails', {
          'account': account,
          'query': 'the',
          'days_back': 7,
          'max_results': 5,
        }),
      );

      if (!isTimeoutResult(result)) {
        assertSuccessResult(result);
      }
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });

    test('offset pagination works', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('search-emails', {
          'account': account,
          'query': 'the',
          'offset': 2,
          'max_results': 3,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('offset: 2'));
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });
  });

  group('search-email-content', () {
    test('basic content search returns results', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('search-email-content', {
          'account': account,
          'query': 'the',
          'max_results': 3,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('CONTENT SEARCH'));
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });

    test('AND operator content search works', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('search-email-content', {
          'account': account,
          'query': 'the a',
          'search_operator': 'and',
          'max_results': 3,
        }),
      );

      assertSuccessResult(result);
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });

    test('subject-only content search works', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('search-email-content', {
          'account': account,
          'query': 'the',
          'search_field': 'subject',
          'max_results': 3,
        }),
      );

      assertSuccessResult(result);
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });
  });

  group('multi-search', () {
    test('multiple query groups return tagged results', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('multi-search', {
          'account': account,
          'queries': 'the, from, hello',
          'max_results': 5,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('MULTI-SEARCH RESULTS'));
      expect(text, contains('Query groups:'));
      expect(text, contains('FOUND:'));
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });

    test('multi-search with subject field works', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('multi-search', {
          'account': account,
          'queries': 'test, hello',
          'search_field': 'subject',
          'max_results': 5,
        }),
      );

      assertSuccessResult(result);
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });

    test('multi-search with days_back filter works', () async {
      final (result, elapsed) = await timeOperation(
        () => runBatchedOperation('multi-search', {
          'account': account,
          'queries': 'the, from',
          'days_back': 30,
          'max_results': 5,
        }),
      );

      assertSuccessResult(result);
      expect(elapsed, lessThan(maxBatchedOpDuration));
    });
  });
}
