// Batched handlers for search-emails and multi-search operations.
//
// Uses mdfind (Spotlight CLI) for fast message discovery with keyword,
// sender, and date filtering pushed into the Spotlight query. Metadata
// is extracted via mdls and .emlx parsing.

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../batch_helpers.dart';
import '../mdfind_helpers.dart';

/// Batch size for metadata fetching.
const _metadataBatchSize = 100;

/// Batched search-emails handler.
///
/// Uses mdfind to find matching .emlx files, then fetches metadata
/// and applies Dart-side post-filters for read_status, has_attachments,
/// subject_keyword, and sender exact match.
Future<void> runBatchedSearchEmails({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final account = args['account'] as String;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final query = args['query'] as String?;
  final subjectKeyword = args['subject_keyword'] as String?;
  final sender = args['sender'] as String?;
  final hasAttachments = args['has_attachments'] as bool?;
  final readStatus = args['read_status'] as String? ?? 'all';
  final maxResults = args['max_results'] as int? ?? 20;
  final offset = args['offset'] as int? ?? 0;
  final daysBack = args['days_back'] as int? ?? 0;
  final startDate = args['start_date'] as String?;
  final endDate = args['end_date'] as String?;
  final searchOperator = args['search_operator'] as String? ?? 'or';
  final searchField = args['search_field'] as String? ?? 'all';

  // Write header chunk
  session.chunks.add(
    'SEARCH RESULTS\n\n'
    'Searching in: $mailbox\n'
    'Account: $account\n\n',
  );

  // Build mdfind query with keyword filters
  await extra.sendProgress(0, message: 'Searching emails via Spotlight...');

  List<String> files;
  final keywords = (query != null && query.isNotEmpty)
      ? query.split(' ').where((k) => k.trim().isNotEmpty).toList()
      : <String>[];

  try {
    if (keywords.isNotEmpty) {
      files = await _searchWithKeywords(
        account: account,
        mailbox: mailbox,
        keywords: keywords,
        searchField: searchField,
        searchOperator: searchOperator,
        daysBack: daysBack,
        startDate: startDate,
        endDate: endDate,
      );
    } else {
      files = await fetchEmailFiles(
        account: account,
        mailbox: mailbox,
        daysBack: daysBack,
        startDate: startDate,
        endDate: endDate,
      );
    }
  } catch (e) {
    session.chunks.add('Error searching: $e\n');
    session.isComplete = true;
    await extra.sendProgress(1, message: 'search-emails completed');
    return;
  }

  // Get metadata from mdfind results
  final allMetadata = await fetchEmailMetadata(files);

  if (allMetadata.isEmpty) {
    final fdaWarning = await getFullDiskAccessWarningIfNeeded();
    session.chunks.add(
      '========================================\n'
      'FOUND: 0 matching email(s), showing 0 (offset: $offset)\n'
      '${fdaWarning != null ? 'WARNING: $fdaWarning\n' : ''}'
      '========================================\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'search-emails completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${allMetadata.length} messages, processing...');

  // Process metadata — apply post-filters and format output
  final batches = batchList(allMetadata, _metadataBatchSize);
  var matchedCount = 0;
  var resultCount = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return; // cancelled
    if (resultCount >= maxResults) break;

    final batch = batches[i];

    final batchOutput = StringBuffer();
    for (final meta in batch) {
      // Apply Dart-side post-filters
      if (subjectKeyword != null &&
          !(meta['subject'] ?? '')
              .toLowerCase()
              .contains(subjectKeyword.toLowerCase())) {
        continue;
      }
      if (sender != null &&
          !(meta['sender'] ?? '')
              .toLowerCase()
              .contains(sender.toLowerCase())) {
        continue;
      }
      if (hasAttachments == true && meta['has_attachments'] != 'true') {
        continue;
      }
      if (hasAttachments == false && meta['has_attachments'] == 'true') {
        continue;
      }
      if (readStatus == 'read' && meta['read_status'] != 'read') continue;
      if (readStatus == 'unread' && meta['read_status'] != 'unread') {
        continue;
      }

      matchedCount++;
      if (matchedCount > offset && resultCount < maxResults) {
        final readIndicator =
            meta['read_status'] == 'read' ? '✓' : '✉';
        batchOutput.writeln('$readIndicator ${meta['subject']}');
        batchOutput.writeln('   From: ${meta['sender']}');
        batchOutput.writeln('   Date: ${meta['date']}');
        batchOutput.writeln('   Mailbox: ${meta['mailbox']}');
        batchOutput.writeln('   ID: ${meta['message_id']}');
        batchOutput.writeln();
        resultCount++;
      }
    }

    if (batchOutput.isNotEmpty) {
      session.chunks.add(batchOutput.toString());
    }

    scanned += batch.length;
    await extra.sendProgress(0,
        message: 'Processed $scanned of ${allMetadata.length} messages, '
            'found $matchedCount matches');
  }

  session.chunks.add(
    '========================================\n'
    'FOUND: $matchedCount matching email(s), showing $resultCount '
    '(offset: $offset)\n'
    '========================================\n',
  );
  session.isComplete = true;
  await extra.sendProgress(1, message: 'search-emails completed');
}

/// Batched multi-search handler.
///
/// Runs separate mdfind queries per query group, deduplicates results,
/// and tags each result with matching groups in Dart.
Future<void> runBatchedMultiSearch({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final account = args['account'] as String;
  final queries = args['queries'] as String;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final maxResults = args['max_results'] as int? ?? 30;
  final offset = args['offset'] as int? ?? 0;
  final daysBack = args['days_back'] as int? ?? 0;
  final searchField = args['search_field'] as String? ?? 'all';

  final useSubject = searchField == 'all' || searchField == 'subject';
  final useSender = searchField == 'all' || searchField == 'sender';

  // Parse query groups
  final groups = queries
      .split(',')
      .map((g) =>
          g.trim().split(' ').where((k) => k.trim().isNotEmpty).toList())
      .where((g) => g.isNotEmpty)
      .toList();

  if (groups.isEmpty) {
    session.chunks.add('ERROR: No valid query groups found.\n');
    session.isComplete = true;
    return;
  }

  session.chunks.add(
    'MULTI-SEARCH RESULTS\n'
    'Query groups: $queries\n'
    'Account: $account\n'
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n',
  );

  // Run mdfind for all keywords combined (broad match), then tag in Dart
  await extra.sendProgress(0, message: 'Searching via Spotlight...');

  final allKeywords = <String>{};
  for (final group in groups) {
    allKeywords.addAll(group.map((k) => k.toLowerCase()));
  }

  List<String> files;
  try {
    files = await _searchWithKeywords(
      account: account,
      mailbox: mailbox,
      keywords: allKeywords.toList(),
      searchField: searchField,
      searchOperator: 'or', // Broad OR match for all keywords
      daysBack: daysBack,
    );
  } catch (e) {
    session.chunks.add('Error searching: $e\n');
    session.isComplete = true;
    return;
  }

  // Get metadata from mdfind results
  final allMetadata = await fetchEmailMetadata(files);

  if (allMetadata.isEmpty) {
    final fdaWarning = await getFullDiskAccessWarningIfNeeded();
    session.chunks.add(
      '========================================\n'
      'FOUND: 0 matching email(s), showing 0 (offset: $offset)\n'
      'Query groups searched: ${groups.length}\n'
      '${fdaWarning != null ? 'WARNING: $fdaWarning\n' : ''}'
      '========================================\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'multi-search completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${allMetadata.length} messages, processing...');

  // Process metadata and tag with query groups
  final batches = batchList(allMetadata, _metadataBatchSize);
  var matchedCount = 0;
  var resultCount = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return;
    if (resultCount >= maxResults) break;

    final batch = batches[i];

    final batchOutput = StringBuffer();
    for (final meta in batch) {
      matchedCount++;
      if (matchedCount > offset && resultCount < maxResults) {
        final readIndicator =
            meta['read_status'] == 'read' ? '✓' : '✉';
        final subject = meta['subject'] ?? '';
        final senderVal = meta['sender'] ?? '';

        // Dart-side group tagging
        final lowerSubject = subject.toLowerCase();
        final lowerSender = senderVal.toLowerCase();
        final matchedGroups = <String>[];
        for (final group in groups) {
          final groupLabel = group.join(' ');
          final matches = group.any((keyword) {
            final lk = keyword.toLowerCase();
            if (useSubject && lowerSubject.contains(lk)) return true;
            if (useSender && lowerSender.contains(lk)) return true;
            return false;
          });
          if (matches) matchedGroups.add('[$groupLabel]');
        }

        batchOutput.writeln('$readIndicator $subject');
        batchOutput.writeln('   From: $senderVal');
        batchOutput.writeln('   Date: ${meta['date']}');
        batchOutput.writeln('   Mailbox: ${meta['mailbox']}');
        batchOutput.writeln('   Matched: ${matchedGroups.join(' ')}');
        batchOutput.writeln('   ID: ${meta['message_id']}');
        batchOutput.writeln();
        resultCount++;
      }
    }

    if (batchOutput.isNotEmpty) {
      session.chunks.add(batchOutput.toString());
    }

    scanned += batch.length;
    await extra.sendProgress(0,
        message: 'Processed $scanned of ${allMetadata.length} messages, '
            'found $matchedCount matches');
  }

  session.chunks.add(
    '========================================\n'
    'FOUND: $matchedCount matching email(s), showing $resultCount '
    '(offset: $offset)\n'
    'Query groups searched: ${groups.length}\n'
    '========================================\n',
  );
  session.isComplete = true;
  await extra.sendProgress(1, message: 'multi-search completed');
}

// ─────────────────────── Search helpers ───────────────────────

/// Searches for emails using mdfind with keyword filters.
///
/// Builds a Spotlight query with keyword conditions pushed into the
/// query based on searchField and searchOperator.
Future<List<String>> _searchWithKeywords({
  required String account,
  required String mailbox,
  required List<String> keywords,
  required String searchField,
  required String searchOperator,
  int daysBack = 0,
  String? startDate,
  String? endDate,
}) async {
  // Resolve scope directory
  final accountPaths = await resolveAccountPaths();
  String? scopeDir;

  for (final entry in accountPaths.entries) {
    if (entry.key.toLowerCase().contains(account.toLowerCase()) ||
        account.toLowerCase().contains(entry.key.toLowerCase())) {
      if (mailbox == 'All') {
        scopeDir = entry.value;
      } else {
        scopeDir = await findMailboxDirectory(
              accountPath: entry.value,
              mailbox: mailbox,
            ) ??
            entry.value;
      }
      break;
    }
  }

  scopeDir ??= defaultMailDirectory;

  // Build date filters
  DateTime? dateAfter;
  DateTime? dateBefore;

  if (daysBack > 0) {
    dateAfter = DateTime.now().subtract(Duration(days: daysBack));
  }
  if (startDate != null) dateAfter = DateTime.parse(startDate);
  if (endDate != null) {
    dateBefore = DateTime.parse(endDate)
        .add(const Duration(hours: 23, minutes: 59, seconds: 59));
  }

  // Build keyword conditions for Spotlight
  final keywordConditions = <String>[];
  for (final keyword in keywords) {
    final fieldConditions = <String>[];
    if (searchField == 'all' || searchField == 'subject') {
      fieldConditions
          .add('kMDItemTitle == "*${_escapeSpotlight(keyword)}*"cd');
    }
    if (searchField == 'all' || searchField == 'sender') {
      fieldConditions
          .add('kMDItemAuthors == "*${_escapeSpotlight(keyword)}*"cd');
    }
    if (fieldConditions.isEmpty) continue;
    if (fieldConditions.length == 1) {
      keywordConditions.add(fieldConditions.first);
    } else {
      keywordConditions.add('(${fieldConditions.join(' || ')})');
    }
  }

  // Build the complete query
  final conditions = <String>[
    'kMDItemContentType == "$emlxContentType"',
  ];

  if (dateAfter != null) {
    conditions.add(
      'kMDItemContentCreationDate >= \$time.iso(${dateAfter.toUtc().toIso8601String()})',
    );
  }
  if (dateBefore != null) {
    conditions.add(
      'kMDItemContentCreationDate <= \$time.iso(${dateBefore.toUtc().toIso8601String()})',
    );
  }

  if (keywordConditions.isNotEmpty) {
    final joiner = searchOperator == 'and' ? ' && ' : ' || ';
    conditions.add('(${keywordConditions.join(joiner)})');
  }

  final query = conditions.join(' && ');
  return runMdfind(query, directory: scopeDir);
}

/// Escapes special characters for Spotlight query strings.
String _escapeSpotlight(String value) {
  return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}
