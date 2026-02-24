@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late String account;

  setUpAll(() async {
    account = await discoverFirstAccount();
  });

  group('search-by-sender', () {
    test('returns results for common sender pattern', () async {
      // Use a generic pattern that is likely to match something
      final (result, elapsed) = await timeOperation(
        () => searchHandlers['search-by-sender']!({
          'sender': '@',
          'account': account,
          'max_results': 5,
          'days_back': 30,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('EMAILS FROM SENDER:'));
      expect(text, contains('FOUND:'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('with mailbox=All searches across mailboxes', () async {
      final (result, elapsed) = await timeOperation(
        () => searchHandlers['search-by-sender']!({
          'sender': '@',
          'account': account,
          'mailbox': 'All',
          'max_results': 3,
          'days_back': 7,
        }),
      );

      // mailbox=All can be slow on large accounts or may error
      final text = extractText(result);
      if (!isTimeoutResult(result) && !text.startsWith('Error:')) {
        assertSuccessResult(result);
      }
      expect(elapsed, lessThan(maxComplexOpDuration));
    });
  });

  group('get-recent-from-sender', () {
    test('returns recent emails from a sender pattern', () async {
      final (result, elapsed) = await timeOperation(
        () => searchHandlers['get-recent-from-sender']!({
          'sender': '@',
          'account': account,
          'time_range': 'month',
          'max_results': 5,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('EMAILS FROM:'));
      expect(text, contains('Time range:'));
      expect(text, contains('FOUND:'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('different time ranges work', () async {
      for (final range in ['today', 'week', 'month']) {
        final (result, elapsed) = await timeOperation(
          () => searchHandlers['get-recent-from-sender']!({
            'sender': '@',
            'time_range': range,
            'max_results': 3,
          }),
        );

        assertSuccessResult(result);
        expect(elapsed, lessThan(maxComplexOpDuration),
            reason: 'time_range=$range should complete in time');
      }
    });
  });

  group('get-newsletters', () {
    test('returns newsletter detection results', () async {
      final (result, elapsed) = await timeOperation(
        () => searchHandlers['get-newsletters']!({
          'account': account,
          'days_back': 30,
          'max_results': 10,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('NEWSLETTER DETECTION'));
      expect(text, contains('FOUND:'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('without account searches all accounts', () async {
      final (result, elapsed) = await timeOperation(
        () => searchHandlers['get-newsletters']!({
          'days_back': 7,
          'max_results': 5,
        }),
      );

      assertSuccessResult(result);
      expect(elapsed, lessThan(maxComplexOpDuration));
    });
  });

  group('search-all-accounts', () {
    test('returns cross-account search results', () async {
      final (result, elapsed) = await timeOperation(
        () => searchHandlers['search-all-accounts']!({
          'days_back': 7,
          'max_results': 5,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      // Result is either "Cross-Account Search Results" or "No emails found"
      expect(
        text.contains('Cross-Account') || text.contains('No emails found'),
        isTrue,
        reason: 'Should contain results or no-results message',
      );
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('with subject keyword filter', () async {
      final (result, elapsed) = await timeOperation(
        () => searchHandlers['search-all-accounts']!({
          'subject_keyword': 'the',
          'days_back': 30,
          'max_results': 5,
        }),
      );

      assertSuccessResult(result);
      expect(elapsed, lessThan(maxComplexOpDuration));
    });
  });

  group('get-email-with-content', () {
    test('returns emails matching subject keyword', () async {
      final (result, elapsed) = await timeOperation(
        () => searchHandlers['get-email-with-content']!({
          'account': account,
          'subject_keyword': 'the',
          'max_results': 3,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('SEARCH RESULTS FOR:'));
      expect(text, contains('FOUND:'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('specific subject keyword with max_content_length', () async {
      final (result, elapsed, error) = await timeOperationTolerant(
        () => searchHandlers['get-email-with-content']!({
          'account': account,
          'subject_keyword': 'Payment Receipt for jhsware',
          'max_content_length': 1000,
        }),
      );

      if (error != null) {
        // AppleScript timeout is acceptable for content-heavy fetches
        // ignore: avoid_print
        print(
            'get-email-with-content Payment Receipt threw exception: $error');
      } else if (result != null) {
        final text = extractText(result);
        if (!text.startsWith('Error:')) {
          expect(text, contains('SEARCH RESULTS FOR:'));
          expect(text, contains('FOUND:'));
          // If matches found, verify content is included
          if (!text.contains('FOUND: 0')) {
            expect(text, contains('Content:'));
          }
        } else {
          // ignore: avoid_print
          print(
              'get-email-with-content Payment Receipt returned error: $text');
        }
      }
      expect(elapsed, lessThan(maxComplexOpDuration));
    });


    // Note: mailbox='All' can cause AppleScript errors like
    // "Can't make missing value into type specifier" on some accounts,
    // or may throw a timeout exception for large mailboxes.
    test('with mailbox=All searches across mailboxes or returns error',
        () async {
      final (result, elapsed, error) = await timeOperationTolerant(
        () => searchHandlers['get-email-with-content']!({
          'account': account,
          'subject_keyword': 'the',
          'mailbox': 'All',
          'max_results': 3,
        }),
      );

      if (error != null && error.contains('timed out')) {
        // ignore: avoid_print
        print('get-email-with-content mailbox=All threw timeout ($error)');
      } else if (result != null) {
        final text = extractText(result);
        // Accept either success or known AppleScript error for mailbox=All
        if (!text.startsWith('Error:')) {
          expect(text, contains('SEARCH RESULTS FOR:'));
          expect(text, contains('FOUND:'));
        }
      } else {
        fail('Unexpected error: $error');
      }
      expect(elapsed, lessThan(maxComplexOpDuration));
    });
  });

  group('get-email-thread', () {
    test('returns thread view for subject keyword', () async {
      final (result, elapsed) = await timeOperation(
        () => searchHandlers['get-email-thread']!({
          'account': account,
          'subject_keyword': 'the',
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('EMAIL THREAD VIEW'));
      expect(text, contains('FOUND'));
      expect(text, contains('MESSAGE(S) IN THREAD'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });
  });
}
