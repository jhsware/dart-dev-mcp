// Batched handlers for cross-account search operations.
//
// Uses mdfind (Spotlight CLI) for fast message discovery with sender,
// keyword, and date filtering pushed into the Spotlight query. Metadata
// is extracted via mdls and .emlx parsing.
//
// Operations:
// - search-by-sender: Find emails from a sender across accounts/mailboxes
// - search-all-accounts: Cross-account unified search (INBOX only)
// - get-newsletters: Newsletter detection across accounts (INBOX only)

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../batch_helpers.dart';
import '../constants.dart';
import '../mdfind_helpers.dart';

/// Batch size for metadata fetching.
const _metadataBatchSize = 100;

/// Batched search-by-sender handler.
///
/// Uses mdfind with kMDItemAuthors to find emails from a sender across
/// accounts and mailboxes.
Future<void> runBatchedSearchBySender({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final sender = args['sender'] as String;
  final account = args['account'] as String?;
  final daysBack = args['days_back'] as int? ?? 30;
  final maxResults = args['max_results'] as int? ?? 20;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final offset = args['offset'] as int? ?? 0;

  session.chunks.add(
    'EMAILS FROM SENDER: $sender\n'
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n',
  );

  await extra.sendProgress(0, message: 'Searching via Spotlight...');

  // Build mdfind query with sender filter
  final escaped = _escapeSpotlight(sender);
  final conditions = <String>[
    'kMDItemContentType == "$emlxContentType"',
    'kMDItemAuthors == "*$escaped*"cd',
  ];

  // Date filter
  if (daysBack > 0) {
    final dateAfter = DateTime.now().subtract(Duration(days: daysBack));
    conditions.add(
      'kMDItemContentCreationDate >= \$time.iso(${dateAfter.toUtc().toIso8601String()})',
    );
  }

  final query = conditions.join(' && ');

  // Determine scope directory
  String? scopeDir;
  if (account != null) {
    final accountPaths = await resolveAccountPaths();
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
  }

  scopeDir ??= defaultMailDirectory;

  List<String> files;
  try {
    files = await runMdfind(query, directory: scopeDir);
    // Filter system folders for non-specific mailbox searches
    if (mailbox == 'All' || account == null) {
      files = files.where((path) => !_isSystemFolderPath(path)).toList();
    }
  } catch (e) {
    session.chunks.add('Error searching: $e\n');
    session.isComplete = true;
    await extra.sendProgress(1, message: 'search-by-sender completed');
    return;
  }

  if (files.isEmpty) {
    session.chunks.add(
      '========================================\n'
      'FOUND: 0 matching email(s) from sender, '
      'showing 0 (offset: $offset)\n'
      '========================================\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'search-by-sender completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${files.length} messages, fetching metadata...');

  // Fetch metadata in batches
  final batches = batchList(files, _metadataBatchSize);
  var matchedCount = 0;
  var resultCount = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return;
    if (resultCount >= maxResults) break;

    final batch = batches[i];

    try {
      final metadataList = await fetchEmailMetadata(batch);

      final batchOutput = StringBuffer();
      for (final meta in metadataList) {
        matchedCount++;
        if (matchedCount > offset && resultCount < maxResults) {
          final readIndicator = meta['read_status'] == 'read' ? '✓' : '✉';
          batchOutput.writeln('$readIndicator ${meta['subject']}');
          batchOutput.writeln('   From: ${meta['sender']}');
          batchOutput.writeln('   Date: ${meta['date']}');
          batchOutput.writeln('   Account: ${meta['account']}');
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
    'FOUND: $matchedCount matching email(s) from sender, '
    'showing $resultCount (offset: $offset)\n'
    '========================================\n',
  );
  session.isComplete = true;
  await extra.sendProgress(1, message: 'search-by-sender completed');
}

/// Batched search-all-accounts handler.
///
/// Uses mdfind scoped to the entire Mail directory for cross-account
/// search with optional subject/sender filters.
Future<void> runBatchedSearchAllAccounts({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final subjectKeyword = args['subject_keyword'] as String?;
  final sender = args['sender'] as String?;
  final daysBack = args['days_back'] as int? ?? 7;
  final maxResults = args['max_results'] as int? ?? 30;

  session.chunks.add(
    '=== Cross-Account Search Results ===\n---\n\n',
  );

  await extra.sendProgress(0, message: 'Searching via Spotlight...');

  // Build mdfind query with optional keyword/sender filters
  final conditions = <String>[
    'kMDItemContentType == "$emlxContentType"',
  ];

  if (subjectKeyword != null) {
    final escaped = _escapeSpotlight(subjectKeyword);
    conditions.add('kMDItemTitle == "*$escaped*"cd');
  }
  if (sender != null) {
    final escaped = _escapeSpotlight(sender);
    conditions.add('kMDItemAuthors == "*$escaped*"cd');
  }
  if (daysBack > 0) {
    final dateAfter = DateTime.now().subtract(Duration(days: daysBack));
    conditions.add(
      'kMDItemContentCreationDate >= \$time.iso(${dateAfter.toUtc().toIso8601String()})',
    );
  }

  final query = conditions.join(' && ');

  // Search across all accounts — scope to entire Mail directory
  // but filter to INBOX mailboxes only
  List<String> files;
  try {
    files = await runMdfind(query, directory: defaultMailDirectory);
    // Only keep INBOX files (filter out non-INBOX mailboxes and system folders)
    files = files.where((path) {
      final lower = path.toLowerCase();
      return lower.contains('/inbox.mbox/') && !_isSystemFolderPath(path);
    }).toList();
  } catch (e) {
    session.chunks.add('Error searching: $e\n');
    session.isComplete = true;
    await extra.sendProgress(1, message: 'search-all-accounts completed');
    return;
  }

  if (files.isEmpty) {
    session.chunks.add(
      'No emails found matching your criteria across all accounts.\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'search-all-accounts completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${files.length} messages, fetching metadata...');

  // Fetch metadata in batches
  final batches = batchList(files, _metadataBatchSize);
  var totalResults = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return;
    if (totalResults >= maxResults) break;

    final batch = batches[i];

    try {
      final metadataList = await fetchEmailMetadata(batch);

      final batchOutput = StringBuffer();
      for (final meta in metadataList) {
        totalResults++;
        if (totalResults <= maxResults) {
          final readStatus =
              meta['read_status'] == 'read' ? 'Read' : 'UNREAD';
          batchOutput.writeln('Account: ${meta['account']}');
          batchOutput.writeln('Subject: ${meta['subject']}');
          batchOutput.writeln('From: ${meta['sender']}');
          batchOutput.writeln('Date: ${meta['date']}');
          batchOutput.writeln('Status: $readStatus');
          batchOutput.writeln('ID: ${meta['message_id']}');
          batchOutput.writeln('\n---');
        }
      }
      if (batchOutput.isNotEmpty) {
        session.chunks.add(batchOutput.toString());
      }
    } catch (e) {
      // Skip batch errors silently
    }

    scanned += batch.length;
    await extra.sendProgress(0,
        message: 'Processed $scanned of ${files.length} messages');
  }

  if (totalResults == 0) {
    session.chunks.add(
      'No emails found matching your criteria across all accounts.\n',
    );
  } else {
    session.chunks.add(
      '\nFound $totalResults email(s)\n',
    );
  }
  session.isComplete = true;
  await extra.sendProgress(1, message: 'search-all-accounts completed');
}

/// Batched get-newsletters handler.
///
/// Uses mdfind with newsletter sender pattern matching via kMDItemAuthors
/// to detect newsletters across accounts.
Future<void> runBatchedGetNewsletters({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final account = args['account'] as String?;
  final daysBack = args['days_back'] as int? ?? 7;
  final maxResults = args['max_results'] as int? ?? 25;

  session.chunks.add(
    '📰 NEWSLETTER DETECTION\n'
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n',
  );

  await extra.sendProgress(0, message: 'Searching via Spotlight...');

  // Build OR conditions for all newsletter patterns
  final patternConditions = <String>[];
  for (final pattern in newsletterPlatformPatterns) {
    patternConditions.add(
      'kMDItemAuthors == "*${_escapeSpotlight(pattern)}*"cd',
    );
  }
  for (final pattern in newsletterKeywordPatterns) {
    patternConditions.add(
      'kMDItemAuthors == "*${_escapeSpotlight(pattern)}*"cd',
    );
  }

  final conditions = <String>[
    'kMDItemContentType == "$emlxContentType"',
    '(${patternConditions.join(' || ')})',
  ];

  if (daysBack > 0) {
    final dateAfter = DateTime.now().subtract(Duration(days: daysBack));
    conditions.add(
      'kMDItemContentCreationDate >= \$time.iso(${dateAfter.toUtc().toIso8601String()})',
    );
  }

  final query = conditions.join(' && ');

  // Determine scope
  String? scopeDir;
  if (account != null) {
    final accountPaths = await resolveAccountPaths();
    for (final entry in accountPaths.entries) {
      if (entry.key.toLowerCase().contains(account.toLowerCase()) ||
          account.toLowerCase().contains(entry.key.toLowerCase())) {
        scopeDir = entry.value;
        break;
      }
    }
  }
  scopeDir ??= defaultMailDirectory;

  List<String> files;
  try {
    files = await runMdfind(query, directory: scopeDir);
    // Only INBOX mailboxes
    files = files.where((path) {
      final lower = path.toLowerCase();
      return lower.contains('/inbox.mbox/') && !_isSystemFolderPath(path);
    }).toList();
  } catch (e) {
    session.chunks.add('Error searching: $e\n');
    session.isComplete = true;
    await extra.sendProgress(1, message: 'get-newsletters completed');
    return;
  }

  if (files.isEmpty) {
    session.chunks.add(
      '========================================\n'
      'FOUND: 0 newsletter(s)\n'
      '========================================\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'get-newsletters completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${files.length} messages, fetching metadata...');

  // Fetch metadata in batches
  final batches = batchList(files, _metadataBatchSize);
  var resultCount = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return;
    if (resultCount >= maxResults) break;

    final batch = batches[i];

    try {
      final metadataList = await fetchEmailMetadata(batch);

      final batchOutput = StringBuffer();
      for (final meta in metadataList) {
        resultCount++;
        if (resultCount <= maxResults) {
          final readIndicator = meta['read_status'] == 'read' ? '✓' : '✉';
          batchOutput.writeln('$readIndicator ${meta['subject']}');
          batchOutput.writeln('   From: ${meta['sender']}');
          batchOutput.writeln('   Date: ${meta['date']}');
          batchOutput.writeln('   Account: ${meta['account']}');
          batchOutput.writeln('   ID: ${meta['message_id']}');
          batchOutput.writeln();
        }
      }
      if (batchOutput.isNotEmpty) {
        session.chunks.add(batchOutput.toString());
      }
    } catch (e) {
      // Skip batch errors silently
    }

    scanned += batch.length;
    await extra.sendProgress(0,
        message: 'Processed $scanned of ${files.length} messages');
  }

  session.chunks.add(
    '========================================\n'
    'FOUND: $resultCount newsletter(s)\n'
    '========================================\n',
  );
  session.isComplete = true;
  await extra.sendProgress(1, message: 'get-newsletters completed');
}

// ─────────────────────── Shared helpers ───────────────────────

/// System folder names to skip when searching "All" mailboxes.
final _systemFolderPatterns = [
  ...skipFolders.map((f) => '/$f.mbox/'),
  '/Junk Email.mbox/',
  '/Deleted Items.mbox/',
  '/Sent Items.mbox/',
  '/Sent Messages.mbox/',
];

/// Checks if an .emlx file path is within a system folder.
bool _isSystemFolderPath(String path) {
  final lowerPath = path.toLowerCase();
  return _systemFolderPatterns.any(
    (pattern) => lowerPath.contains(pattern.toLowerCase()),
  );
}

/// Escapes special characters for Spotlight query strings.
String _escapeSpotlight(String value) {
  return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}
