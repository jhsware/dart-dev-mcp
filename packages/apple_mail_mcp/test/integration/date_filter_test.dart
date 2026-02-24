// Integration tests for date-filtered email operations.
//
// Verifies that the safe AppleScript date construction pattern works
// correctly across various date ranges, including edge cases that
// would trigger the classic month-overflow bug.

@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:apple_mail_mcp/apple_mail_mcp.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late String account;

  setUpAll(() async {
    account = await discoverFirstAccount();
  });

  group('list-emails date filtering', () {
    test('with start_date 30 days ago returns valid JSON', () async {
      final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30));
      final dateStr = _formatDate(thirtyDaysAgo);

      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['list-emails']!({
          'account': account,
          'limit': 5,
          'start_date': dateStr,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed, contains('emails'));
      expect(parsed, contains('pagination'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('with start_date 1 year ago returns valid JSON or times out',
        () async {
      final oneYearAgo = DateTime.now().subtract(const Duration(days: 365));
      final dateStr = _formatDate(oneYearAgo);

      final (result, elapsed, error) = await timeOperationTolerant(
        () => inboxHandlers['list-emails']!({
          'account': account,
          'limit': 3,
          'start_date': dateStr,
        }),
      );

      if (error != null) {
        // Timeout is acceptable for very old dates with large mailboxes
        expect(error, contains('timed out'));
      } else {
        assertSuccessResult(result!);
        final text = extractText(result);
        final parsed = jsonDecode(text) as Map<String, dynamic>;
        expect(parsed, contains('emails'));
      }
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('with start_date on month boundary (Jan 31)', () async {
      // Jan 31 can cause overflow if current date is in a shorter month
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['list-emails']!({
          'account': account,
          'limit': 3,
          'start_date': '2025-01-31',
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed, contains('emails'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('with start_date Feb 28 (potential overflow date)', () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['list-emails']!({
          'account': account,
          'limit': 3,
          'start_date': '2025-02-28',
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed, contains('emails'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('with start_date Feb 29 leap year', () async {
      final (result, elapsed, error) = await timeOperationTolerant(
        () => inboxHandlers['list-emails']!({
          'account': account,
          'limit': 3,
          'start_date': '2024-02-29',
        }),
      );

      if (error != null) {
        expect(error, contains('timed out'));
      } else {
        assertSuccessResult(result!);
        final text = extractText(result);
        final parsed = jsonDecode(text) as Map<String, dynamic>;
        expect(parsed, contains('emails'));
      }
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('with start_date in the originally failing range (Jan 21-25)',
        () async {
      // These dates consistently failed before the fix when running
      // on certain current dates (e.g. March 31)
      for (final day in [21, 22, 23, 24, 25]) {
        final dateStr = '2025-01-${day.toString().padLeft(2, '0')}';
        final (result, _, error) = await timeOperationTolerant(
          () => inboxHandlers['list-emails']!({
            'account': account,
            'limit': 3,
            'start_date': dateStr,
          }),
        );

        if (error != null) {
          expect(error, contains('timed out'),
              reason: 'Date $dateStr should not cause an AppleScript error');
        } else {
          assertSuccessResult(result!);
          final text = extractText(result);
          expect(text, isNot(contains('ERROR')),
              reason: 'Date $dateStr should not produce errors');
        }
      }
    });

    test('with year boundary start_date (Dec 31 previous year)', () async {
      final (result, elapsed) = await timeOperation(
        () => inboxHandlers['list-emails']!({
          'account': account,
          'limit': 3,
          'start_date': '2024-12-31',
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed, contains('emails'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });
  });

  group('fetchMessageIds date filtering', () {
    test('with start_date and end_date returns message IDs', () async {
      // Use a recent 7-day window
      final endDate = DateTime.now().subtract(const Duration(days: 1));
      final startDate = endDate.subtract(const Duration(days: 7));

      final (ids, elapsed) = await timeOperation(
        () => fetchMessageIds(
          account: account,
          mailbox: 'INBOX',
          startDate: _formatDate(startDate),
          endDate: _formatDate(endDate),
        ),
      );

      // We just verify it doesn't error — may be empty if no emails in range
      expect(ids, isA<List<String>>());
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('with month boundary dates (crossing Jan to Feb)', () async {
      final sw = Stopwatch()..start();
      try {
        final ids = await fetchMessageIds(
          account: account,
          mailbox: 'INBOX',
          startDate: '2025-01-28',
          endDate: '2025-02-03',
        );
        sw.stop();
        expect(ids, isA<List<String>>());
      } on Exception catch (e) {
        sw.stop();
        expect(e.toString(), contains('timed out'));
      }
      expect(sw.elapsed, lessThan(maxComplexOpDuration));
    });

    test('with dates far in the past (6+ months)', () async {
      final sixMonthsAgo =
          DateTime.now().subtract(const Duration(days: 180));
      final sevenMonthsAgo =
          DateTime.now().subtract(const Duration(days: 210));

      final sw = Stopwatch()..start();
      try {
        final ids = await fetchMessageIds(
          account: account,
          mailbox: 'INBOX',
          startDate: _formatDate(sevenMonthsAgo),
          endDate: _formatDate(sixMonthsAgo),
        );
        sw.stop();
        expect(ids, isA<List<String>>());
      } on Exception catch (e) {
        sw.stop();
        expect(e.toString(), contains('timed out'));
      }
      expect(sw.elapsed, lessThan(maxComplexOpDuration));
    });


    test('with daysBack parameter works correctly', () async {
      final (ids, elapsed) = await timeOperation(
        () => fetchMessageIds(
          account: account,
          mailbox: 'INBOX',
          daysBack: 7,
        ),
      );

      expect(ids, isA<List<String>>());
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('with Feb edge case start and end dates', () async {
      // Feb 28 to Mar 1 — crosses the February boundary
      final sw = Stopwatch()..start();
      try {
        final ids = await fetchMessageIds(
          account: account,
          mailbox: 'INBOX',
          startDate: '2025-02-28',
          endDate: '2025-03-01',
        );
        sw.stop();
        expect(ids, isA<List<String>>());
      } on Exception catch (e) {
        sw.stop();
        expect(e.toString(), contains('timed out'));
      }
      expect(sw.elapsed, lessThan(maxComplexOpDuration));
    });

  });
}

String _formatDate(DateTime dt) {
  final y = dt.year.toString();
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
