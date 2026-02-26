// Batched search-email-content handler.
//
// Uses mdfind with kMDItemTextContent for fast full-text body search
// via the Spotlight index, replacing the slow two-phase AppleScript
// approach that fetched `content of aMessage` per batch.

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../batch_helpers.dart';
import '../mdfind_helpers.dart';

/// Batch size for metadata fetching.
const _metadataBatchSize = 100;

/// Batched search-email-content handler.
///
/// Uses mdfind kMDItemTextContent for body search, kMDItemTitle for
/// subject search — a single Spotlight query replaces hundreds of
/// AppleScript invocations.
Future<void> runBatchedSearchEmailContent({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final account = args['account'] as String;
  final query = args['query'] as String;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final maxResults = args['max_results'] as int? ?? 10;
  final offset = args['offset'] as int? ?? 0;
  final daysBack = args['days_back'] as int? ?? 0;
  final startDate = args['start_date'] as String?;
  final endDate = args['end_date'] as String?;
  final searchOperator = args['search_operator'] as String? ?? 'or';
  final searchField = args['search_field'] as String? ?? 'all';

  final keywords =
      query.split(' ').where((k) => k.trim().isNotEmpty).toList();

  // Write header chunk
  session.chunks.add(
    '🔎 CONTENT SEARCH: $query\n'
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    '⚡ Using Spotlight full-text search\n\n',
  );

  // Resolve scope directory
  await extra.sendProgress(0, message: 'Searching via Spotlight...');

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
    final escaped = keyword.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    final fieldConditions = <String>[];

    if (searchField == 'all' || searchField == 'subject') {
      fieldConditions.add('kMDItemTitle == "*$escaped*"cd');
    }
    if (searchField == 'all' || searchField == 'body') {
      fieldConditions.add('kMDItemTextContent == "*$escaped*"cd');
    }

    if (fieldConditions.isEmpty) continue;
    if (fieldConditions.length == 1) {
      keywordConditions.add(fieldConditions.first);
    } else {
      keywordConditions.add('(${fieldConditions.join(' || ')})');
    }
  }

  // Build complete query
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

  final mdfindQuery = conditions.join(' && ');

  List<String> files;
  try {
    files = await runMdfind(mdfindQuery, directory: scopeDir);
  } catch (e) {
    session.chunks.add('Error searching: $e\n');
    session.isComplete = true;
    await extra.sendProgress(1, message: 'search-email-content completed');
    return;
  }

  if (files.isEmpty) {
    final fdaWarning = await getFullDiskAccessWarningIfNeeded();
    session.chunks.add(
      '========================================\n'
      'FOUND: 0 emails matching "$query"\n'
      '${fdaWarning != null ? 'WARNING: $fdaWarning\n' : ''}'
      '========================================\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'search-email-content completed');
    return;
  }

  await extra.sendProgress(0,
      message:
          'Found ${files.length} matching messages, fetching metadata...');

  // Fetch metadata in batches
  final batches = batchList(files, _metadataBatchSize);
  var matchedCount = 0;
  var resultCount = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return; // cancelled
    if (resultCount >= maxResults) break;

    final batch = batches[i];

    try {
      final metadataList = await fetchEmailMetadata(batch);

      final batchOutput = StringBuffer();
      for (final meta in metadataList) {
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
    } catch (e) {
      session.chunks.add('Warning: Batch ${i + 1} error: $e\n');
    }

    scanned += batch.length;
    await extra.sendProgress(0,
        message: 'Processed $scanned of ${files.length} messages, '
            'found $matchedCount matches');
  }

  session.chunks.add(
    '========================================\n'
    'FOUND: $matchedCount email(s) matching "$query"\n'
    '========================================\n',
  );
  session.isComplete = true;
  await extra.sendProgress(1, message: 'search-email-content completed');
}
