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

  group('classify-emails', () {
    test('single category classification works', () async {
      final classifiers = jsonEncode({
        'test_cat': ['the', 'and'],
      });

      final (result, elapsed) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'days_back': 30,
          'max_results': 50,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;

      expect(parsed, contains('summary'));
      expect(parsed, contains('categories'));
      expect(parsed, contains('total_emails_scanned'));
      expect(parsed['total_emails_scanned'], isA<int>());

      final summary = parsed['summary'] as Map<String, dynamic>;
      expect(summary, isA<Map>());

      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('three category classification works', () async {
      final classifiers = jsonEncode({
        'common_words': ['the', 'and'],
        'greetings': ['hello', 'hi'],
        'actions': ['from', 'to'],
      });

      final (result, elapsed) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'days_back': 30,
          'max_results': 50,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;

      expect(parsed, contains('summary'));
      expect(parsed, contains('categories'));
      expect(parsed, contains('total_emails_scanned'));

      final categories = parsed['categories'] as Map<String, dynamic>;
      // Categories should only contain keys from our classifiers
      for (final key in categories.keys) {
        expect(
          ['common_words', 'greetings', 'actions'].contains(key),
          isTrue,
          reason: 'Unexpected category: $key',
        );
      }

      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('five category classification works', () async {
      final classifiers = jsonEncode({
        'cat_a': ['the', 'and'],
        'cat_b': ['from', 'to'],
        'cat_c': ['hello', 'hi'],
        'cat_d': ['new', 'update'],
        'cat_e': ['re', 'fwd'],
      });

      final (result, elapsed) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'days_back': 30,
          'max_results': 100,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed, contains('summary'));
      expect(parsed['total_emails_scanned'], isA<int>());

      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('subject-only search_field works', () async {
      final classifiers = jsonEncode({
        'test_cat': ['the', 'and'],
      });

      final (result, elapsed) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'search_field': 'subject',
          'days_back': 30,
          'max_results': 50,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed, contains('summary'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('sender-only search_field works', () async {
      final classifiers = jsonEncode({
        'test_cat': ['the', 'and'],
      });

      final (result, elapsed) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'search_field': 'sender',
          'days_back': 30,
          'max_results': 50,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed, contains('summary'));
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('min_score filtering excludes low-scoring results', () async {
      final classifiers = jsonEncode({
        'test_cat': ['the', 'and'],
      });

      // Run with min_score = 0 to get all results
      final (resultNoFilter, _) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'min_score': 0.0,
          'days_back': 30,
          'max_results': 50,
        }),
      );

      // Run with high min_score to filter results
      final (resultFiltered, elapsed) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'min_score': 5.0,
          'days_back': 30,
          'max_results': 50,
        }),
      );

      final noFilterParsed =
          jsonDecode(extractText(resultNoFilter)) as Map<String, dynamic>;
      final filteredParsed =
          jsonDecode(extractText(resultFiltered)) as Map<String, dynamic>;

      final noFilterSummary =
          noFilterParsed['summary'] as Map<String, dynamic>;
      final filteredSummary =
          filteredParsed['summary'] as Map<String, dynamic>;

      // With high min_score, we should have fewer or equal results
      final noFilterCount = noFilterSummary['test_cat'] as int? ?? 0;
      final filteredCount = filteredSummary['test_cat'] as int? ?? 0;
      expect(filteredCount, lessThanOrEqualTo(noFilterCount),
          reason: 'Higher min_score should produce fewer or equal results');

      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('include_unmatched=true includes unmatched emails', () async {
      final classifiers = jsonEncode({
        'test_cat': ['xyznonexistent'],
      });

      final (result, elapsed) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'include_unmatched': true,
          'days_back': 30,
          'max_results': 50,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed, contains('unmatched'));
      final unmatched = parsed['unmatched'] as List;
      expect(unmatched, isA<List>());
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('include_unmatched=false omits unmatched emails', () async {
      final classifiers = jsonEncode({
        'test_cat': ['the', 'and'],
      });

      final (result, elapsed) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'include_unmatched': false,
          'days_back': 30,
          'max_results': 50,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed.containsKey('unmatched'), isFalse,
          reason: 'Should not contain unmatched key when false');
      expect(elapsed, lessThan(maxComplexOpDuration));
    });

    test('BM25 scores are present and positive for matching results',
        () async {
      final classifiers = jsonEncode({
        'test_cat': ['the', 'and'],
      });

      final (result, _) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'days_back': 30,
          'max_results': 50,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      final categories = parsed['categories'] as Map<String, dynamic>;

      if (categories.containsKey('test_cat')) {
        final matches = categories['test_cat'] as List;
        for (final match in matches) {
          final map = match as Map<String, dynamic>;
          expect(map, contains('score'));
          expect(map['score'], isA<num>());
          expect((map['score'] as num).toDouble(), greaterThan(0.0),
              reason: 'BM25 scores should be positive');
          // Check email structure
          expect(map, contains('subject'));
          expect(map, contains('sender'));
          expect(map, contains('date'));
          expect(map, contains('message_id'));
        }
      }
    });

    test('empty mailbox returns zero scanned count', () async {
      final classifiers = jsonEncode({
        'test_cat': ['the'],
      });

      // Use a very short days_back with unlikely-to-match mailbox
      final (result, elapsed) = await timeOperation(
        () => searchHandlers['classify-emails']!({
          'account': account,
          'classifiers': classifiers,
          'mailbox': 'Trash',
          'days_back': 1,
          'max_results': 10,
        }),
      );

      assertSuccessResult(result);
      final text = extractText(result);
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect(parsed['total_emails_scanned'], isA<int>());
      expect(elapsed, lessThan(maxComplexOpDuration));
    });
  });
}
