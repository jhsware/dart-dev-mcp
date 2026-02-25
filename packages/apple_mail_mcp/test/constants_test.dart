import 'package:test/test.dart';
import 'package:apple_mail_mcp/apple_mail_mcp.dart';

void main() {
  group('constants', () {
    test('newsletterPlatformPatterns is non-empty', () {
      expect(newsletterPlatformPatterns, isNotEmpty);
      expect(newsletterPlatformPatterns, contains('substack.com'));
      expect(newsletterPlatformPatterns, contains('mailchimp.com'));
    });

    test('newsletterKeywordPatterns is non-empty', () {
      expect(newsletterKeywordPatterns, isNotEmpty);
      expect(newsletterKeywordPatterns, contains('newsletter'));
      expect(newsletterKeywordPatterns, contains('digest'));
    });

    test('skipFolders contains critical entries', () {
      expect(skipFolders, isNotEmpty);
      expect(skipFolders, contains('Trash'));
      expect(skipFolders, contains('Junk'));
      expect(skipFolders, contains('Sent'));
      expect(skipFolders, contains('Drafts'));
    });

    test('threadPrefixes contains Re: and Fwd:', () {
      expect(threadPrefixes, isNotEmpty);
      expect(threadPrefixes, contains('Re: '));
      expect(threadPrefixes, contains('Fwd: '));
    });

    test('timeRanges has expected keys', () {
      expect(timeRanges, isNotEmpty);
      expect(timeRanges.containsKey('today'), isTrue);
      expect(timeRanges.containsKey('yesterday'), isTrue);
      expect(timeRanges.containsKey('week'), isTrue);
      expect(timeRanges.containsKey('month'), isTrue);
      expect(timeRanges.containsKey('all'), isTrue);
    });

    test('timeRanges today is 1 day', () {
      expect(timeRanges['today'], equals(1));
    });

    test('timeRanges all is 0 (no filter)', () {
      expect(timeRanges['all'], equals(0));
    });

    test('timeRanges week is 7', () {
      expect(timeRanges['week'], equals(7));
    });

    test('skipFolders contains all expected system folders', () {
      for (final folder in [
        'Trash',
        'Junk',
        'Spam',
        'Sent',
        'Sent Messages',
        'Drafts',
        'Deleted Messages',
        'Deleted Items',
        'Archive',
        'Notes'
      ]) {
        expect(skipFolders, contains(folder),
            reason: 'skipFolders should contain $folder');
      }
    });

    test('threadPrefixes includes all common prefixes', () {
      expect(threadPrefixes, contains('RE: '));
      expect(threadPrefixes, contains('FW: '));
      expect(threadPrefixes, contains('Fw: '));
    });
  });

  group('email field constants', () {
    test('defaultEmailFields contains expected fields', () {
      expect(defaultEmailFields, contains('sender'));
      expect(defaultEmailFields, contains('subject'));
      expect(defaultEmailFields, contains('date'));
      expect(defaultEmailFields, contains('message_id'));
    });

    test('allEmailFields is a superset of defaultEmailFields', () {
      for (final field in defaultEmailFields) {
        expect(allEmailFields, contains(field),
            reason: 'allEmailFields should contain default field "$field"');
      }
    });

    test('allEmailFields contains extended fields', () {
      expect(allEmailFields, contains('read_status'));
      expect(allEmailFields, contains('mailbox'));
      expect(allEmailFields, contains('account'));
      expect(allEmailFields, contains('attachments'));
    });
  });
}