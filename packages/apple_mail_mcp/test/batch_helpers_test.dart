import 'package:test/test.dart';
import 'package:apple_mail_mcp/apple_mail_mcp.dart';

void main() {
  group('batchList', () {
    test('splits list into batches of given size', () {
      final result = batchList([1, 2, 3, 4, 5], 2);
      expect(result, [
        [1, 2],
        [3, 4],
        [5],
      ]);
    });

    test('returns empty list for empty input', () {
      final result = batchList<int>([], 5);
      expect(result, isEmpty);
    });

    test('returns single batch when list is smaller than batch size', () {
      final result = batchList([1, 2, 3], 10);
      expect(result, [
        [1, 2, 3],
      ]);
    });

    test('handles exact multiple of batch size', () {
      final result = batchList([1, 2, 3, 4], 2);
      expect(result, [
        [1, 2],
        [3, 4],
      ]);
    });

    test('handles batch size of 1', () {
      final result = batchList(['a', 'b', 'c'], 1);
      expect(result, [
        ['a'],
        ['b'],
        ['c'],
      ]);
    });

    test('handles list with single element', () {
      final result = batchList([42], 5);
      expect(result, [
        [42],
      ]);
    });
  });

  group('buildMessageIdSet', () {
    test('builds AppleScript set literal from message IDs', () {
      final result = buildMessageIdSet(['id1', 'id2', 'id3']);
      expect(result, '{"id1", "id2", "id3"}');
    });

    test('escapes special characters in IDs', () {
      final result = buildMessageIdSet(['id"with"quotes', 'id\\backslash']);
      expect(result, '{"id\\"with\\"quotes", "id\\\\backslash"}');
    });

    test('handles single ID', () {
      final result = buildMessageIdSet(['only-one']);
      expect(result, '{"only-one"}');
    });

    test('handles empty list', () {
      final result = buildMessageIdSet([]);
      expect(result, '{}');
    });
  });

  group('progress_wrapper constants', () {
    test('slowOperations does not contain search-email-content', () {
      expect(slowOperations, isNot(contains('search-email-content')));
    });

    test('batchedOperations contains search-email-content', () {
      expect(batchedOperations, contains('search-email-content'));
    });

    test('slowOperations and batchedOperations do not overlap', () {
      final overlap = slowOperations.intersection(batchedOperations);
      expect(overlap, isEmpty);
    });
  });

  group('server operations', () {
    test('allOperations still contains search-email-content', () {
      expect(allOperations, contains('search-email-content'));
    });

    test('allOperations contains exactly 25 operations', () {
      expect(allOperations.length, equals(25));
    });

    test('allOperations contains all batched operations', () {
      for (final op in batchedOperations) {
        expect(allOperations, contains(op));
      }
    });
  });
}
