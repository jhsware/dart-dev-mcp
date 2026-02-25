import 'package:test/test.dart';
import 'package:apple_mail_mcp/apple_mail_mcp.dart';

/// Helper to build a valid .emlx string with correct byte count.
String buildEmlx(String emailData, {String plist = ''}) {
  final byteCount = emailData.length;
  return '$byteCount\n$emailData$plist';
}

void main() {
  group('parseEmlxPath', () {
    test('extracts account and mailbox from standard INBOX path', () {
      final result = parseEmlxPath(
        '/Users/x/Library/Mail/V10/ABC-UUID/INBOX.mbox/Messages/12345.emlx',
      );
      expect(result, isNotNull);
      expect(result!.accountDir, 'ABC-UUID');
      expect(result.mailbox, 'INBOX');
      expect(result.fileId, '12345');
    });

    test('extracts mailbox with spaces', () {
      final result = parseEmlxPath(
        '/Users/x/Library/Mail/V10/ACC123/Sent Messages.mbox/Messages/999.emlx',
      );
      expect(result, isNotNull);
      expect(result!.mailbox, 'Sent Messages');
      expect(result.fileId, '999');
    });

    test('handles nested mailbox paths', () {
      final result = parseEmlxPath(
        '/Users/x/Library/Mail/V10/ACC/Work.mbox/Messages/42.emlx',
      );
      expect(result, isNotNull);
      expect(result!.mailbox, 'Work');
      expect(result.accountDir, 'ACC');
    });

    test('returns null for non-emlx path', () {
      final result = parseEmlxPath('/Users/x/Documents/file.txt');
      expect(result, isNull);
    });

    test('returns null for path without .mbox segment', () {
      final result = parseEmlxPath('/Users/x/Library/Mail/V10/messages.emlx');
      expect(result, isNull);
    });

    test('handles different Mail version directories', () {
      final result = parseEmlxPath(
        '/Users/x/Library/Mail/V9/ACCOUNT/Drafts.mbox/Messages/1.emlx',
      );
      expect(result, isNotNull);
      expect(result!.accountDir, 'ACCOUNT');
      expect(result.mailbox, 'Drafts');
    });

    test('toString provides readable output', () {
      final info = EmlxPathInfo(
        accountDir: 'ACC',
        mailbox: 'INBOX',
        fileId: '123',
      );
      expect(info.toString(),
          'EmlxPathInfo(account: ACC, mailbox: INBOX, id: 123)');
    });
  });

  group('parseEmlxContentFromString', () {
    final emailData = 'From: sender@example.com\n'
        'To: recipient@example.com\n'
        'Subject: Test Email Subject\n'
        'Date: Mon, 15 Jan 2024 10:30:00 +0000\n'
        'Message-ID: <unique-id-123@example.com>\n'
        '\n'
        'This is the body of the email message.\n'
        'It has multiple lines.\n';

    final plist = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        '<dict>\n'
        '\t<key>flags</key>\n'
        '\t<integer>8590195713</integer>\n'
        '</dict>\n'
        '</plist>\n';

    final sampleEmlx = buildEmlx(emailData, plist: plist);

    test('extracts Message-ID header', () {
      final result = parseEmlxContentFromString(sampleEmlx);
      expect(result, isNotNull);
      expect(result!.messageId, 'unique-id-123@example.com');
    });

    test('extracts Subject header', () {
      final result = parseEmlxContentFromString(sampleEmlx);
      expect(result, isNotNull);
      expect(result!.subject, 'Test Email Subject');
    });

    test('extracts From header as sender', () {
      final result = parseEmlxContentFromString(sampleEmlx);
      expect(result, isNotNull);
      expect(result!.sender, 'sender@example.com');
    });

    test('extracts Date header', () {
      final result = parseEmlxContentFromString(sampleEmlx);
      expect(result, isNotNull);
      expect(result!.dateStr, 'Mon, 15 Jan 2024 10:30:00 +0000');
    });

    test('extracts body preview', () {
      final result = parseEmlxContentFromString(sampleEmlx);
      expect(result, isNotNull);
      expect(result!.bodyPreview, contains('body of the email'));
    });

    test('parses read status from plist flags', () {
      // 8590195713 & 1 = 1 (read)
      final result = parseEmlxContentFromString(sampleEmlx);
      expect(result, isNotNull);
      expect(result!.isRead, isTrue);
    });

    test('detects unread status', () {
      final unreadEmail = 'From: test@test.com\nSubject: Unread\n\nbody\n';
      final unreadPlist = '<plist version="1.0"><dict>'
          '<key>flags</key><integer>0</integer>'
          '</dict></plist>\n';
      final unreadEmlx = buildEmlx(unreadEmail, plist: unreadPlist);
      final result = parseEmlxContentFromString(unreadEmlx);
      expect(result, isNotNull);
      expect(result!.isRead, isFalse);
    });

    test('returns null for empty content', () {
      final result = parseEmlxContentFromString('');
      expect(result, isNull);
    });

    test('returns null when first line is not a number', () {
      final result = parseEmlxContentFromString('not a number\nFrom: x\n');
      expect(result, isNull);
    });

    test('handles emlx with no plist section', () {
      final email = 'From: x@y.com\nSubject: Hi\n\nbody';
      final noPlist = buildEmlx(email);
      final result = parseEmlxContentFromString(noPlist);
      expect(result, isNotNull);
      expect(result!.sender, 'x@y.com');
      expect(result.isRead, isFalse); // default when no flags
    });

    test('handles multiline header values (folded headers)', () {
      final foldedEmail =
          'Subject: Very long subject that\n continues here\nFrom: a@b.com\n\nbody text';
      final foldedEmlx = buildEmlx(foldedEmail);
      final result = parseEmlxContentFromString(foldedEmlx);
      expect(result, isNotNull);
      expect(result!.subject, contains('Very long subject'));
      expect(result.subject, contains('continues here'));
    });

    test('truncates body preview to requested length', () {
      final longEmail = 'From: a@b.com\nSubject: X\n\n${'A' * 500}';
      final longBody = buildEmlx(longEmail);
      final result =
          parseEmlxContentFromString(longBody, bodyPreviewLength: 50);
      expect(result, isNotNull);
      expect(result!.bodyPreview!.length, lessThanOrEqualTo(54)); // 50 + "..."
    });

    test('strips HTML from body preview', () {
      final htmlEmail =
          'From: a@b.com\nSubject: X\nContent-Type: text/html\n\n<html><body><p>Hello World</p></body></html>';
      final htmlBody = buildEmlx(htmlEmail);
      final result = parseEmlxContentFromString(htmlBody);
      expect(result, isNotNull);
      if (result!.bodyPreview != null) {
        expect(result.bodyPreview, isNot(contains('<html>')));
        expect(result.bodyPreview, isNot(contains('<p>')));
      }
    });

    test('detects attachments from flags', () {
      final email = 'From: a@b.com\nSubject: Hi\n\nbody\n';
      final attachPlist = '<plist version="1.0"><dict>'
          '<key>flags</key><integer>5</integer>'
          '</dict></plist>\n';
      final withAttachments = buildEmlx(email, plist: attachPlist);
      // flags=5: bit 0 (read=1) + bit 2 (attachments=4)
      final result = parseEmlxContentFromString(withAttachments);
      expect(result, isNotNull);
      expect(result!.isRead, isTrue);
      expect(result.hasAttachments, isTrue);
    });
  });

  group('EmlxContent defaults', () {
    test('has sensible defaults', () {
      const content = EmlxContent();
      expect(content.messageId, isNull);
      expect(content.subject, isNull);
      expect(content.sender, isNull);
      expect(content.dateStr, isNull);
      expect(content.isRead, isFalse);
      expect(content.hasAttachments, isFalse);
      expect(content.bodyPreview, isNull);
    });
  });
}
