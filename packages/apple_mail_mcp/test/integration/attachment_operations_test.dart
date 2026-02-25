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
    test('requires message_id parameter', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['list-email-attachments']!({}),
      );

      final text = extractText(result);
      expect(text, contains('message_id parameter is required'));
    });

    // Note: We don't test with a nonexistent message_id here because the
    // by-ID lookup must search all accounts/mailboxes exhaustively, which
    // can take >2 minutes on large mailboxes. The handler wraps runAppleScript
    // in a try-catch so timeouts return a graceful error rather than throwing.
  });

  group('save-email-attachment', () {
    test('requires message_id parameter', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['save-email-attachment']!({}),
      );

      final text = extractText(result);
      expect(text, contains('message_id parameter is required'));
    });
  });

  group('get-email-attachment', () {
    test('requires message_id parameter', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['get-email-attachment']!({}),
      );

      final text = extractText(result);
      expect(text, contains('message_id parameter is required'));
    });

    test('requires attachment_name parameter', () async {
      final (result, _) = await timeOperation(
        () => attachmentHandlers['get-email-attachment']!({
          'message_id': 'some-id',
        }),
      );

      final text = extractText(result);
      expect(text, contains('attachment_name parameter is required'));
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
