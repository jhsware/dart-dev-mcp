import 'package:test/test.dart';
import 'package:apple_mail_mcp/apple_mail_mcp.dart';

void main() {
  group('buildMdfindQuery', () {
    test('returns content type filter when no parameters given', () {
      final query = buildMdfindQuery();
      expect(query, 'kMDItemContentType == "com.apple.mail.emlx"');
    });

    test('adds title filter with case-insensitive wildcard', () {
      final query = buildMdfindQuery(titleContains: 'invoice');
      expect(query, contains('kMDItemTitle == "*invoice*"cd'));
    });

    test('adds author filter with case-insensitive wildcard', () {
      final query = buildMdfindQuery(authorContains: 'john@example.com');
      expect(query, contains('kMDItemAuthors == "*john@example.com*"cd'));
    });

    test('adds text content filter', () {
      final query = buildMdfindQuery(textContains: 'quarterly report');
      expect(
          query, contains('kMDItemTextContent == "*quarterly report*"cd'));
    });

    test('adds date after filter with ISO format', () {
      final date = DateTime.utc(2024, 6, 15, 0, 0, 0);
      final query = buildMdfindQuery(dateAfter: date);
      expect(
        query,
        contains(r'kMDItemContentCreationDate >= $time.iso('),
      );
      expect(query, contains('2024-06-15'));
    });

    test('adds date before filter with ISO format', () {
      final date = DateTime.utc(2024, 12, 31, 23, 59, 59);
      final query = buildMdfindQuery(dateBefore: date);
      expect(
        query,
        contains(r'kMDItemContentCreationDate <= $time.iso('),
      );
      expect(query, contains('2024-12-31'));
    });

    test('combines multiple filters with &&', () {
      final query = buildMdfindQuery(
        titleContains: 'test',
        authorContains: 'sender',
      );
      expect(query, contains(' && '));
      // Should have 3 conditions: content type + title + author
      expect(' && '.allMatches(query).length, 2);
    });

    test('escapes quotes in filter values', () {
      final query = buildMdfindQuery(titleContains: 'test "quoted"');
      expect(query, contains(r'test \"quoted\"'));
    });

    test('escapes backslashes in filter values', () {
      final query = buildMdfindQuery(titleContains: r'test\path');
      expect(query, contains(r'test\\path'));
    });
  });

  group('parseMdlsOutput', () {
    test('parses simple key-value pairs', () {
      final output = '''
kMDItemTitle = "Hello World"
kMDItemContentType = "com.apple.mail.emlx"
''';
      final result = parseMdlsOutput(output);
      expect(result['kMDItemTitle'], 'Hello World');
      expect(result['kMDItemContentType'], 'com.apple.mail.emlx');
    });

    test('handles array values like kMDItemAuthors', () {
      final output = 'kMDItemAuthors = ("John Doe <john@example.com>")\n';
      final result = parseMdlsOutput(output);
      expect(result['kMDItemAuthors'], 'John Doe <john@example.com>');
    });

    test('skips null values', () {
      final output = '''
kMDItemTitle = "Test"
kMDItemAuthors = (null)
''';
      final result = parseMdlsOutput(output);
      expect(result['kMDItemTitle'], 'Test');
      expect(result.containsKey('kMDItemAuthors'), isFalse);
    });

    test('handles date values without quotes', () {
      final output =
          'kMDItemContentCreationDate = 2024-01-15 10:30:00 +0000\n';
      final result = parseMdlsOutput(output);
      expect(result['kMDItemContentCreationDate'],
          '2024-01-15 10:30:00 +0000');
    });

    test('handles empty output', () {
      final result = parseMdlsOutput('');
      expect(result, isEmpty);
    });

    test('handles lines without equals sign', () {
      final output = '''
kMDItemTitle = "Test"
some garbage line
kMDItemAuthors = ("author")
''';
      final result = parseMdlsOutput(output);
      expect(result.length, 2);
    });
  });

  group('parseMdlsBatchOutput', () {
    test('parses output for multiple files', () {
      final output = '''
kMDItemTitle = "Email 1"
kMDItemAuthors = ("sender1@test.com")

kMDItemTitle = "Email 2"
kMDItemAuthors = ("sender2@test.com")
''';
      final results = parseMdlsBatchOutput(output, 2);
      expect(results.length, 2);
      expect(results[0]['kMDItemTitle'], 'Email 1');
      expect(results[1]['kMDItemTitle'], 'Email 2');
    });

    test('handles file path separators in batch output', () {
      final output = '''
/Users/x/Library/Mail/V10/abc/INBOX.mbox/Messages/1.emlx
kMDItemTitle = "First"
/Users/x/Library/Mail/V10/abc/INBOX.mbox/Messages/2.emlx
kMDItemTitle = "Second"
''';
      final results = parseMdlsBatchOutput(output, 2);
      expect(results.length, 2);
      expect(results[0]['kMDItemTitle'], 'First');
      expect(results[1]['kMDItemTitle'], 'Second');
    });

    test('returns empty list for empty input', () {
      final results = parseMdlsBatchOutput('', 0);
      expect(results, isEmpty);
    });
  });

  group('constants', () {
    test('defaultMailDirectory points to ~/Library/Mail', () {
      expect(defaultMailDirectory, '~/Library/Mail');
    });

    test('emlxContentType is com.apple.mail.emlx', () {
      expect(emlxContentType, 'com.apple.mail.emlx');
    });
  });
}
