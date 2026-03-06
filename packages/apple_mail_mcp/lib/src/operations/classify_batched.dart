// Batched classify-emails handler with progress between phases.
//
// Phase 1: mdfind query to find all matching .emlx files by date range.
//          Requires Full Disk Access to search ~/Library/Mail/.
// Phase 2: Batch-fetch metadata via mdls and .emlx parsing.
// Phase 3: BM25 classification across all fetched emails.
// Results are written to session chunks for polling.


import 'dart:convert';

import 'package:bm25/bm25.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../batch_helpers.dart';



/// Batched classify-emails handler with progress between phases.
///
/// Uses mdfind to find all emails matching date criteria, then
/// batch-fetches subject/sender metadata, and finally runs BM25
/// classification.
///
/// Requires Full Disk Access for mdfind to return results.

Future<void> runBatchedClassifyEmails({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final classifiersJson = args['classifiers'] as String;
  final account = args['account'] as String;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final daysBack = args['days_back'] as int? ?? 30;
  final startDate = args['start_date'] as String?;
  final endDate = args['end_date'] as String?;
  final maxResults = args['max_results'] as int? ?? 200;
  final minScore = (args['min_score'] as num?)?.toDouble() ?? 0.0;
  final searchField = args['search_field'] as String? ?? 'all';
  final includeUnmatched = args['include_unmatched'] as bool? ?? true;

  // Parse classifiers (already validated in server.dart)
  final classifiersRaw = jsonDecode(classifiersJson) as Map<String, dynamic>;
  final classifiers = <String, List<String>>{};
  for (final entry in classifiersRaw.entries) {
    classifiers[entry.key] = (entry.value as List).cast<String>();
  }

  // --- Phase 1: Find emails via mdfind ---
  await extra.sendProgress(0, message: 'Searching emails via Spotlight...');

  List<String> files;
  try {
    files = await fetchEmailFiles(
      account: account,
      mailbox: mailbox,
      daysBack: daysBack,
      startDate: startDate,
      endDate: endDate,
    );
  } catch (e) {
    session.chunks.add('ERROR: Failed to find emails: $e\n');
    session.isComplete = true;
    await extra.sendProgress(1, message: 'classify-emails failed');
    return;
  }

  // --- Phase 2: Batch-fetch metadata via mdls and .emlx parsing ---
  final emails = await fetchEmailMetadata(files);


  if (emails.isEmpty) {
    // Check if empty results are due to missing Full Disk Access
    final fdaWarning = await getFullDiskAccessWarningIfNeeded();
    final output = {
      'summary': <String, int>{},
      'categories': <String, List<Map<String, dynamic>>>{},
      if (includeUnmatched) 'unmatched': <Map<String, dynamic>>[],
      'total_emails_scanned': 0,
      'warning': ?fdaWarning,
    };
    session.chunks.add(const JsonEncoder.withIndent('  ').convert(output));
    session.isComplete = true;
    await extra.sendProgress(1, message: 'classify-emails completed');
    return;
  }

  // --- Phase 3: BM25 classification ---
  await extra.sendProgress(0,
      message: 'Fetched ${emails.length} emails, running classification '
          'across ${classifiers.length} categories...');

  final documents = <BM25Document>[];
  for (var i = 0; i < emails.length; i++) {
    final email = emails[i];
    String text;
    switch (searchField) {
      case 'subject':
        text = email['subject'] ?? '';
      case 'sender':
        text = email['sender'] ?? '';
      default:
        text = '${email['subject'] ?? ''} ${email['sender'] ?? ''}';
    }
    documents.add(BM25Document(id: i, text: text, terms: []));
  }

  final bm25 = await BM25.build(documents);

  final categorizedResults = <String, List<Map<String, dynamic>>>{};
  final matchedIds = <int>{};

  for (final entry in classifiers.entries) {
    final category = entry.key;
    final terms = entry.value;
    final query = terms.join(' ');
    final results = await bm25.search(query, limit: maxResults);
    final categoryMatches = <Map<String, dynamic>>[];

    for (final result in results) {
      if (result.score < minScore) continue;
      final email = emails[result.doc.id];
      matchedIds.add(result.doc.id);
      categoryMatches.add({
        ...email,
        'score': double.parse(result.score.toStringAsFixed(3)),
      });
    }

    if (categoryMatches.isNotEmpty) {
      categorizedResults[category] = categoryMatches;
    }
  }

  // Build output
  final summary = <String, int>{};
  for (final entry in categorizedResults.entries) {
    summary[entry.key] = entry.value.length;
  }

  final unmatched = <Map<String, dynamic>>[];
  if (includeUnmatched) {
    for (var i = 0; i < emails.length; i++) {
      if (!matchedIds.contains(i)) {
        unmatched.add(emails[i]);
      }
    }
    summary['unmatched'] = unmatched.length;
  }

  final output = {
    'summary': summary,
    'categories': categorizedResults,
    if (includeUnmatched) 'unmatched': unmatched,
    'total_emails_scanned': emails.length,
  };

  await bm25.dispose();

  session.chunks.add(const JsonEncoder.withIndent('  ').convert(output));
  session.isComplete = true;
  await extra.sendProgress(1, message: 'classify-emails completed');
}
