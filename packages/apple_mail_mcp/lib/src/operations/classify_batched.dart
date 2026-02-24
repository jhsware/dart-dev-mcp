// Batched classify-emails handler with progress between phases.
//
// Uses the two-phase fetchMessageIds + batch pattern to support arbitrary
// date ranges without a hard cap on the number of emails fetched.
// Phase 1: Fetch all matching message IDs via fetchMessageIds().
// Phase 2: Batch-process IDs in groups of 200 to fetch subject/sender data.
// Phase 3: BM25 classification across all fetched emails.
// Results are written to session chunks for polling.

import 'dart:convert';

import 'package:bm25/bm25.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../core.dart';
import '../batch_helpers.dart';

/// Batch size for metadata fetches (subject/sender are fast).
const _classifyBatchSize = 200;

/// Batched classify-emails handler with progress between phases.
///
/// Uses [fetchMessageIds] to get ALL message IDs matching date criteria,
/// then batch-fetches subject/sender metadata, and finally runs BM25
/// classification. This removes the old 200-message cap and supports
/// arbitrary date ranges via start_date/end_date.
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

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // --- Phase 1: Fetch message IDs ---
  await extra.sendProgress(0, message: 'Fetching message IDs...');

  List<String> allIds;
  try {
    allIds = await fetchMessageIds(
      account: account,
      mailbox: mailbox,
      daysBack: daysBack,
      startDate: startDate,
      endDate: endDate,
    );
  } catch (e) {
    session.chunks.add('ERROR: Failed to fetch message IDs: $e\n');
    session.isComplete = true;
    await extra.sendProgress(1, message: 'classify-emails failed');
    return;
  }

  if (allIds.isEmpty) {
    final output = {
      'summary': <String, int>{},
      'categories': <String, List<Map<String, dynamic>>>{},
      if (includeUnmatched) 'unmatched': <Map<String, dynamic>>[],
      'total_emails_scanned': 0,
    };
    session.chunks.add(const JsonEncoder.withIndent('  ').convert(output));
    session.isComplete = true;
    await extra.sendProgress(1, message: 'classify-emails completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${allIds.length} messages, fetching metadata...');

  // --- Phase 2: Batch-fetch email metadata ---
  final emails = <Map<String, String>>[];
  final batches = batchList(allIds, _classifyBatchSize);
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return; // cancelled

    final batch = batches[i];
    final idSet = buildMessageIdSet(batch);

    // Build mailbox loop
    final mailboxLoopStart = _mailboxLoopStart(mailbox, escapedMailbox);
    final mailboxLoopEnd = _mailboxLoopEnd();

    final script = '''
tell application "Mail"
    set outputText to ""
    set targetAccount to account "$escapedAccount"
    set idSet to $idSet

    $mailboxLoopStart
                    set mailboxMessages to every message of currentMailbox
                    repeat with aMessage in mailboxMessages
                        try
                            set msgId to message id of aMessage
                            if msgId is in idSet then
                                set messageSubject to subject of aMessage
                                set messageSender to sender of aMessage
                                set messageDate to date received of aMessage
                                set outputText to outputText & messageSubject & "|" & messageSender & "|" & (messageDate as string) & "|" & msgId & linefeed
                            end if
                        end try
                    end repeat
    $mailboxLoopEnd

    return outputText
end tell
''';

    try {
      final result = await runAppleScript(script);
      final lines = result
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty);

      for (final line in lines) {
        final parts = line.split('|');
        if (parts.length >= 4) {
          emails.add({
            'subject': parts[0],
            'sender': parts[1],
            'date': parts[2],
            'message_id': parts.sublist(3).join('|'),
          });
        }
      }
    } catch (e) {
      // Log warning but continue with other batches
      session.chunks.add('Warning: Batch ${i + 1} error: $e\n');
    }

    scanned += batch.length;
    await extra.sendProgress(0,
        message: 'Fetched metadata for $scanned of ${allIds.length} messages');
  }

  if (emails.isEmpty) {
    final output = {
      'summary': <String, int>{},
      'categories': <String, List<Map<String, dynamic>>>{},
      if (includeUnmatched) 'unmatched': <Map<String, dynamic>>[],
      'total_emails_scanned': 0,
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

// ─────────────────────── AppleScript helpers ───────────────────────

/// Generates the AppleScript mailbox loop start for batch scripts.
///
/// For "All" mailbox: loops all mailboxes with system folder skipping.
/// For specific mailbox: resolves the single mailbox, wraps in list.
String _mailboxLoopStart(String mailbox, String escapedMailbox) {
  if (mailbox == 'All') {
    return '''
    set searchMailboxes to every mailbox of targetAccount
    repeat with currentMailbox in searchMailboxes
        try
            set mailboxName to name of currentMailbox
            set skipFoldersList to {"Trash", "Junk", "Junk Email", "Deleted Items", "Sent", "Sent Items", "Sent Messages", "Drafts", "Spam", "Deleted Messages"}
            set shouldSkip to false
            repeat with skipFolder in skipFoldersList
                if mailboxName is skipFolder then
                    set shouldSkip to true
                    exit repeat
                end if
            end repeat
            if not shouldSkip then''';
  } else {
    return '''
    try
        set searchMailbox to mailbox "$escapedMailbox" of targetAccount
    on error
        if "$escapedMailbox" is "INBOX" then
            set searchMailbox to mailbox "Inbox" of targetAccount
        else
            error "Mailbox \\"$escapedMailbox\\" not found."
        end if
    end try
    set searchMailboxes to {searchMailbox}
    repeat with currentMailbox in searchMailboxes
        try
            if true then''';
  }
}

/// Generates the AppleScript mailbox loop end.
String _mailboxLoopEnd() {
  return '''
                end if
            end try
        end repeat''';
}
