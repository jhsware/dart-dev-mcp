import 'package:test/test.dart';
import 'package:apple_mail_mcp/apple_mail_mcp.dart';

void main() {
  group('getInboxOperations', () {
    test('returns a map with exactly 8 entries', () {
      final ops = getInboxOperations();
      expect(ops.length, equals(8));
    });

    test('contains all expected inbox operation keys', () {
      final ops = getInboxOperations();
      expect(ops.containsKey('list-inbox-emails'), isTrue);
      expect(ops.containsKey('get-unread-count'), isTrue);
      expect(ops.containsKey('list-accounts'), isTrue);
      expect(ops.containsKey('get-recent-emails'), isTrue);
      expect(ops.containsKey('list-mailboxes'), isTrue);
      expect(ops.containsKey('get-inbox-overview'), isTrue);
      expect(ops.containsKey('list-emails'), isTrue);
      expect(ops.containsKey('get-email-by-id'), isTrue);
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
    test('returns a map with exactly 1 entry (sync-only operations)', () {
      final ops = getSearchOperations();
      expect(ops.length, equals(1));
    });

    test('contains get-recent-from-sender (only non-batched search op)', () {
      final ops = getSearchOperations();
      expect(ops.containsKey('get-recent-from-sender'), isTrue);
    });
  });

  group('getAttachmentOperations', () {
    test('returns a map with exactly 5 entries', () {
      final ops = getAttachmentOperations();
      expect(ops.length, equals(5));
    });

    test('contains all expected attachment operation keys', () {
      final ops = getAttachmentOperations();
      expect(ops.containsKey('save-email-attachment'), isTrue);
      expect(ops.containsKey('list-email-attachments'), isTrue);
      expect(ops.containsKey('get-email-attachment'), isTrue);
      expect(ops.containsKey('get-statistics'), isTrue);
      expect(ops.containsKey('export-emails'), isTrue);
    });
  });

  group('allOperations', () {
    test('contains exactly 25 operations (14 sync + 8 batched + 3 session)',
        () {
      expect(allOperations.length, equals(25));
    });

    test('contains all inbox operations', () {
      expect(allOperations, contains('list-inbox-emails'));
      expect(allOperations, contains('get-unread-count'));
      expect(allOperations, contains('list-accounts'));
      expect(allOperations, contains('list-emails'));
      expect(allOperations, contains('get-email-by-id'));
    });

    test('contains batched search operations', () {
      expect(allOperations, contains('search-emails'));
      expect(allOperations, contains('search-by-sender'));
      expect(allOperations, contains('get-newsletters'));
      expect(allOperations, contains('search-email-content'));
      expect(allOperations, contains('multi-search'));
      expect(allOperations, contains('classify-emails'));
      expect(allOperations, contains('get-email-thread'));
      expect(allOperations, contains('search-all-accounts'));
    });

    test('contains sync search operations', () {
      expect(allOperations, contains('get-recent-from-sender'));
    });

    test('contains all attachment operations', () {
      expect(allOperations, contains('save-email-attachment'));
      expect(allOperations, contains('get-statistics'));
      expect(allOperations, contains('export-emails'));
    });

    test('contains session management operations', () {
      expect(allOperations, contains('get_output'));
      expect(allOperations, contains('list_sessions'));
      expect(allOperations, contains('cancel'));
    });
  });
}

