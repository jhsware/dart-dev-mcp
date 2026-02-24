@Tags(['integration'])
library;

import 'dart:convert';

import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late String account;

  setUpAll(() async {
    account = await discoverFirstAccount();
  });

  group('inbox operations', () {
    test('list-accounts returns at least one account', () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['list-accounts']!({}),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('Mail Accounts:'));
      // At least one account line
      final accountLines =
          text.split('\n').where((l) => l.trimLeft().startsWith('- '));
      expect(accountLines, isNotEmpty,
          reason: 'Should list at least one account');
      expect(elapsed, lessThan(maxSimpleOpDuration),
          reason: 'list-accounts should complete within time limit');
    });

    test('get-unread-count returns counts per account', () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['get-unread-count']!({}),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('Unread Email Counts:'));
      // Should have at least one account with a count
      expect(text, matches(RegExp(r'\d+ unread')),
          reason: 'Should contain at least one unread count');
      expect(elapsed, lessThan(maxSimpleOpDuration));
    });

    test('list-inbox-emails returns email listing', () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['list-inbox-emails']!({'max_emails': 5}),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('INBOX EMAILS'));
      expect(text, contains('TOTAL EMAILS:'));
      expect(elapsed, lessThan(maxSimpleOpDuration));
    });

    test('get-recent-emails returns recent emails for account', () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['get-recent-emails']!({
          'account': account,
          'count': 3,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('RECENT EMAILS'));
      expect(elapsed, lessThan(maxSimpleOpDuration));
    });

    test('list-mailboxes returns mailbox structure', () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['list-mailboxes']!({'account': account}),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('MAILBOXES'));
      expect(elapsed, lessThan(maxSimpleOpDuration));
    });

    test('get-inbox-overview returns comprehensive overview', () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['get-inbox-overview']!({}),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      expect(text, contains('EMAIL INBOX OVERVIEW'));
      expect(text, contains('UNREAD EMAILS BY ACCOUNT'));
      expect(text, contains('MAILBOX STRUCTURE'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('list-emails returns valid JSON with pagination', () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['list-emails']!({
          'account': account,
          'limit': 5,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);

      // Should be valid JSON
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed, contains('emails'));
      expect(parsed, contains('pagination'));

      final pagination = parsed['pagination'] as Map<String, dynamic>;
      expect(pagination, contains('offset'));
      expect(pagination, contains('limit'));
      expect(pagination, contains('total_available'));
      expect(pagination, contains('has_more'));

      // Emails should be a list
      final emails = parsed['emails'] as List;
      expect(emails, isA<List>());
      // Each email should have structural fields (don't check content)
      for (final email in emails) {
        final map = email as Map<String, dynamic>;
        // Default fields include sender, subject, date, message_id
        expect(map, contains('subject'));
      }

      expect(elapsed, lessThan(maxSimpleOpDuration));
    });

    test('get-email-by-id with invalid ID returns error', () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['get-email-by-id']!({
          'message_id': 'nonexistent-id-integration-test-12345',
        }),
      );

      // This should return an error about not found
      final text = extractText(result);
      expect(
        text.contains('not found') || text.contains('No email found'),
        isTrue,
        reason: 'Should indicate email not found, got: $text',
      );
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('list-emails with custom fields returns requested fields',
        () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['list-emails']!({
          'account': account,
          'limit': 3,
          'fields': 'sender,subject,date',
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      final emails = parsed['emails'] as List;
      for (final email in emails) {
        final map = email as Map<String, dynamic>;
        expect(map, contains('subject'));
        expect(map, contains('sender'));
      }
      expect(elapsed, lessThan(maxSimpleOpDuration));
    });
  });
}
