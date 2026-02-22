import 'package:apple_mail_mcp/src/core.dart';
import 'package:test/test.dart';

void main() {
  group('escapeAppleScript', () {
    test('escapes backslashes', () {
      expect(escapeAppleScript(r'path\to\file'), equals(r'path\\to\\file'));
    });

    test('escapes double quotes', () {
      expect(escapeAppleScript('say "hello"'), equals(r'say \"hello\"'));
    });

    test('escapes combined backslashes and quotes', () {
      expect(
        escapeAppleScript(r'path\to\"file"'),
        equals(r'path\\to\\\"file\"'),
      );
    });

    test('returns empty string unchanged', () {
      expect(escapeAppleScript(''), equals(''));
    });

    test('returns safe strings unchanged', () {
      expect(escapeAppleScript('hello world'), equals('hello world'));
    });
  });

  group('parseEmailList', () {
    test('parses formatted email output', () {
      const output = '''
✉ Test Subject One
   From: sender@test.example
   Date: 2025-01-15 10:30:00

✓ Test Subject Two
   From: other@test.example
   Date: 2025-01-14 09:00:00
   Preview: This is a preview.
''';
      final result = parseEmailList(output);
      expect(result.length, equals(2));

      expect(result[0]['read'], equals('false'));
      expect(result[0]['subject'], equals('Test Subject One'));
      expect(result[0]['sender'], equals('sender@test.example'));
      expect(result[0]['date'], equals('2025-01-15 10:30:00'));

      expect(result[1]['read'], equals('true'));
      expect(result[1]['subject'], equals('Test Subject Two'));
      expect(result[1]['preview'], equals('This is a preview.'));
    });

    test('returns empty list for empty input', () {
      expect(parseEmailList(''), isEmpty);
      expect(parseEmailList('   '), isEmpty);
    });

    test('parses single email', () {
      const output = '''
✉ Single Email
   From: user@example.test
''';
      final result = parseEmailList(output);
      expect(result.length, equals(1));
      expect(result[0]['subject'], equals('Single Email'));
      expect(result[0]['sender'], equals('user@example.test'));
    });

    test('parses Account and Mailbox fields', () {
      const output = '''
✓ Thread Email
   From: user@example.test
   Date: 2025-01-10
   Account: TestAccount
   Mailbox: INBOX
''';
      final result = parseEmailList(output);
      expect(result.length, equals(1));
      expect(result[0]['account'], equals('TestAccount'));
      expect(result[0]['mailbox'], equals('INBOX'));
    });
  });

  group('template helpers', () {
    test('inboxMailboxScript contains INBOX fallback', () {
      final script = inboxMailboxScript(
        varName: 'inboxMailbox',
        accountVar: 'anAccount',
      );
      expect(script, contains('mailbox "INBOX"'));
      expect(script, contains('mailbox "Inbox"'));
      expect(script, contains('on error'));
    });

    test('contentPreviewScript contains truncation logic', () {
      final script = contentPreviewScript(maxLength: 300);
      expect(script, contains('300'));
      expect(script, contains('content of aMessage'));
      expect(script, contains('contentPreview'));
    });

    test('dateCutoffScript returns empty for non-positive daysBack', () {
      expect(dateCutoffScript(daysBack: 0), equals(''));
      expect(dateCutoffScript(daysBack: -1), equals(''));
    });

    test('dateCutoffScript contains days formula for positive daysBack', () {
      final script = dateCutoffScript(daysBack: 30);
      expect(script, contains('30'));
      expect(script, contains('targetDate'));
      expect(script, contains('current date'));
    });

    test('skipFoldersCondition lists all skip folders', () {
      final condition = skipFoldersCondition();
      expect(condition, contains('Trash'));
      expect(condition, contains('Junk'));
      expect(condition, contains('Sent'));
      expect(condition, contains('Drafts'));
      expect(condition, contains('mailboxName is not in'));
    });

    test('lowercaseHandler is a non-empty string', () {
      expect(lowercaseHandler, isNotEmpty);
      expect(lowercaseHandler, contains('on lowercase'));
      expect(lowercaseHandler, contains('tr'));
    });
  });
}
