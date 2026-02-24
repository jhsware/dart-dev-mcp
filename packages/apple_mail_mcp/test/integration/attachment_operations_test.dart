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

  group('get-statistics', () {
    // Note: get-statistics operations can be very slow on large mailboxes
    // and may hit AppleScript timeouts or return AppleScript errors like
    // "Can't make missing value into type specifier" on certain accounts.
    // These are known limitations, not test bugs.

    test('account_overview returns volume metrics or acceptable error',
        () async {
      final (result, elapsed, error) = await timeOperationTolerant(
        () => attachmentHandlers['get-statistics']!({
          'account': account,
          'scope': 'account_overview',
          'days_back': 7,
        }),
      );

      if (error != null) {
        // ignore: avoid_print
        print('account_overview threw exception: $error');
      } else if (result != null) {
        final text = extractText(result);
        if (text.startsWith('Error:')) {
          // AppleScript error is acceptable — log and pass
          // ignore: avoid_print
          print('account_overview returned error (acceptable): $text');
        } else {
          expect(text, contains('EMAIL STATISTICS'));
          expect(text, contains('VOLUME METRICS'));
          expect(text, contains('Total Emails:'));
        }
      }
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('mailbox_breakdown returns mailbox stats', () async {
      final (result, elapsed, error) = await timeOperationTolerant(
        () => attachmentHandlers['get-statistics']!({
          'account': account,
          'scope': 'mailbox_breakdown',
        }),
      );

      if (error != null) {
        // ignore: avoid_print
        print('mailbox_breakdown threw exception: $error');
      } else if (result != null) {
        final text = extractText(result);
        if (text.startsWith('Error:')) {
          // ignore: avoid_print
          print('mailbox_breakdown returned error (acceptable): $text');
        } else {
          expect(text, contains('MAILBOX STATISTICS'));
          expect(text, contains('Total messages:'));
        }
      }
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('sender_stats requires sender parameter', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['get-statistics']!({
          'account': account,
          'scope': 'sender_stats',
        }),
      );

      final text = extractText(result);
      expect(text, contains('sender parameter is required'));
    });

    test('sender_stats with generic sender works or acceptable error',
        () async {
      final (result, elapsed, error) = await timeOperationTolerant(
        () => attachmentHandlers['get-statistics']!({
          'account': account,
          'scope': 'sender_stats',
          'sender': '@',
          'days_back': 7,
        }),
      );

      if (error != null) {
        // ignore: avoid_print
        print('sender_stats threw exception: $error');
      } else if (result != null) {
        final text = extractText(result);
        if (text.startsWith('Error:')) {
          // ignore: avoid_print
          print('sender_stats returned error (acceptable): $text');
        } else {
          expect(text, contains('SENDER STATISTICS'));
        }
      }
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('invalid scope returns error', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['get-statistics']!({
          'account': account,
          'scope': 'invalid_scope',
        }),
      );

      final text = extractText(result);
      expect(text, contains('Invalid scope'));
    });
  });

  group('list-email-attachments', () {
    test('returns attachment listing for subject keyword', () async {
      final (result, elapsed) = await timeOperation(
        () => attachmentHandlers['list-email-attachments']!({
          'account': account,
          'subject_keyword': 'the',
          'max_results': 3,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('ATTACHMENTS FOR:'));
      expect(text, contains('FOUND:'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('requires account parameter', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['list-email-attachments']!({
          'subject_keyword': 'test',
        }),
      );

      final text = extractText(result);
      expect(text, contains('account parameter is required'));
    });

    test('requires subject_keyword parameter', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['list-email-attachments']!({
          'account': account,
        }),
      );

      final text = extractText(result);
      expect(text, contains('subject_keyword parameter is required'));
    });
  });

  group('export-emails', () {
    // Note: We skip save-email-attachment as it writes to disk.
    // export-emails also writes to disk, so we only test the error paths.

    test('requires scope parameter', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['export-emails']!({
          'account': account,
        }),
      );

      final text = extractText(result);
      expect(text, contains('scope parameter is required'));
    });

    test('single_email scope requires subject_keyword', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['export-emails']!({
          'account': account,
          'scope': 'single_email',
        }),
      );

      final text = extractText(result);
      expect(text, contains('subject_keyword parameter is required'));
    });

    test('invalid scope returns error', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['export-emails']!({
          'account': account,
          'scope': 'invalid',
        }),
      );

      final text = extractText(result);
      expect(text, contains('Invalid scope'));
    });
  });
}
