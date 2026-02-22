import 'package:test/test.dart';
import 'package:apple_mail_mcp/apple_mail_mcp.dart';

void main() {
  group('getInboxOperations', () {
    test('returns a map with exactly 6 entries', () {
      final ops = getInboxOperations();
      expect(ops.length, equals(6));
    });

    test('contains all expected inbox operation keys', () {
      final ops = getInboxOperations();
      expect(ops.containsKey('list-inbox-emails'), isTrue);
      expect(ops.containsKey('get-unread-count'), isTrue);
      expect(ops.containsKey('list-accounts'), isTrue);
      expect(ops.containsKey('get-recent-emails'), isTrue);
      expect(ops.containsKey('list-mailboxes'), isTrue);
      expect(ops.containsKey('get-inbox-overview'), isTrue);
    });

    test('all values are non-null functions', () {
      final ops = getInboxOperations();
      for (final entry in ops.entries) {
        expect(entry.value, isNotNull,
            reason: '${entry.key} handler should not be null');
      }
    });
  });

  group('getSearchOperations', () {
    test('returns a map with exactly 8 entries', () {
      final ops = getSearchOperations();
      expect(ops.length, equals(8));
    });

    test('contains all expected search operation keys', () {
      final ops = getSearchOperations();
      expect(ops.containsKey('get-email-with-content'), isTrue);
      expect(ops.containsKey('search-emails'), isTrue);
      expect(ops.containsKey('search-by-sender'), isTrue);
      expect(ops.containsKey('search-email-content'), isTrue);
      expect(ops.containsKey('get-newsletters'), isTrue);
      expect(ops.containsKey('get-recent-from-sender'), isTrue);
      expect(ops.containsKey('get-email-thread'), isTrue);
      expect(ops.containsKey('search-all-accounts'), isTrue);
    });
  });

  group('getAttachmentOperations', () {
    test('returns a map with exactly 4 entries', () {
      final ops = getAttachmentOperations();
      expect(ops.length, equals(4));
    });

    test('contains all expected attachment operation keys', () {
      final ops = getAttachmentOperations();
      expect(ops.containsKey('save-email-attachment'), isTrue);
      expect(ops.containsKey('list-email-attachments'), isTrue);
      expect(ops.containsKey('get-statistics'), isTrue);
      expect(ops.containsKey('export-emails'), isTrue);
    });
  });

  group('allOperations', () {
    test('contains exactly 18 operations', () {
      expect(allOperations.length, equals(18));
    });

    test('contains all inbox operations', () {
      expect(allOperations, contains('list-inbox-emails'));
      expect(allOperations, contains('get-unread-count'));
      expect(allOperations, contains('list-accounts'));
    });

    test('contains all search operations', () {
      expect(allOperations, contains('search-emails'));
      expect(allOperations, contains('search-by-sender'));
      expect(allOperations, contains('get-newsletters'));
    });

    test('contains all attachment operations', () {
      expect(allOperations, contains('save-email-attachment'));
      expect(allOperations, contains('get-statistics'));
      expect(allOperations, contains('export-emails'));
    });
  });
}
