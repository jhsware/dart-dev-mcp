// Batched search-email-content handler.
//
// Two-phase approach for body content search:
// Phase 1: Fast subject/sender pre-scan in batches of 200 message IDs
// Phase 2: Body content search on candidate IDs only, in batches of 20
//
// Each batch writes results to session chunks progressively, enabling
// polling via get_output. Cancellation is checked between batches.

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../core.dart';
import '../batch_helpers.dart';

/// Batch size for Phase 1 (subject/sender pre-scan). Larger batches are
/// fine here because we only read lightweight metadata.
const _phase1BatchSize = 200;

/// Batch size for Phase 2 (body content fetch). Kept small because
/// fetching `content of aMessage` is the expensive operation.
const _phase2BatchSize = 20;

/// Batched search-email-content handler.
///
/// Runs as fire-and-forget, writes results to session chunks progressively.
/// Uses a two-phase approach:
/// - Phase 1: Fast subject/sender scan to find candidate message IDs
/// - Phase 2: Body content search on candidates only
///
/// When [searchField] is "body" only, Phase 1 is skipped and all messages
/// go directly to Phase 2.
Future<void> runBatchedSearchEmailContent({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final account = args['account'] as String;
  final query = args['query'] as String;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final searchBody = args['search_body'] as bool? ?? true;
  final maxResults = args['max_results'] as int? ?? 10;
  final offset = args['offset'] as int? ?? 0;
  final daysBack = args['days_back'] as int? ?? 0;
  final startDate = args['start_date'] as String?;
  final endDate = args['end_date'] as String?;
  final searchOperator = args['search_operator'] as String? ?? 'or';
  final searchField = args['search_field'] as String? ?? 'all';

  final keywords =
      query.split(' ').where((k) => k.trim().isNotEmpty).toList();
  final escapedQuery = escapeAppleScript(query.toLowerCase());

  // Write header chunk
  session.chunks.add(
    '🔎 CONTENT SEARCH: $escapedQuery\n'
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    '⚡ Using batched two-phase search\n\n',
  );

  // --- Fetch all message IDs ---
  await extra.sendProgress(0, message: 'Fetching message IDs...');

  final allIds = await fetchMessageIds(
    account: account,
    mailbox: mailbox,
    daysBack: daysBack,
    startDate: startDate,
    endDate: endDate,
  );

  if (allIds.isEmpty) {
    session.chunks.add(
      '========================================\n'
      'FOUND: 0 emails (mailbox is empty or no messages match date filter)\n'
      '========================================\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'search-email-content completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${allIds.length} messages to search');

  // Determine if Phase 1 can pre-filter
  final canPreFilter = searchField != 'body';

  List<String> candidateIds;
  if (canPreFilter) {
    // --- Phase 1: Subject/sender pre-scan ---
    candidateIds = await _runPhase1(
      allIds: allIds,
      account: account,
      mailbox: mailbox,
      keywords: keywords,
      searchOperator: searchOperator,
      searchField: searchField,
      session: session,
      extra: extra,
    );

    if (session.isComplete) return; // cancelled

    if (candidateIds.isEmpty) {
      session.chunks.add(
        '========================================\n'
        'FOUND: 0 emails matching "$escapedQuery" '
        '(scanned ${allIds.length} messages)\n'
        '========================================\n',
      );
      session.isComplete = true;
      await extra.sendProgress(1, message: 'search-email-content completed');
      return;
    }

    // If search_field is "subject" only (no body search needed), we already
    // have our results from Phase 1 metadata. Skip Phase 2.
    if (searchField == 'subject' || !searchBody) {
      session.chunks.add(
        '========================================\n'
        'FOUND: ${candidateIds.length} email(s) matching "$escapedQuery" '
        '(subject-only scan of ${allIds.length} messages)\n'
        '========================================\n',
      );
      session.isComplete = true;
      await extra.sendProgress(1, message: 'search-email-content completed');
      return;
    }
  } else {
    // search_field is "body" — can't pre-filter, use all IDs
    candidateIds = allIds;
  }

  // --- Phase 2: Body content search ---
  final matchCount = await _runPhase2(
    candidateIds: candidateIds,
    account: account,
    mailbox: mailbox,
    keywords: keywords,
    searchOperator: searchOperator,
    searchField: searchField,
    searchBody: searchBody,
    maxResults: maxResults,
    offset: offset,
    session: session,
    extra: extra,
  );

  if (session.isComplete) return; // cancelled

  session.chunks.add(
    '========================================\n'
    'FOUND: $matchCount email(s) matching "$escapedQuery" '
    '(scanned ${allIds.length} messages, '
    '${candidateIds.length} candidates)\n'
    '========================================\n',
  );
  session.isComplete = true;
  await extra.sendProgress(1, message: 'search-email-content completed');
}

/// Phase 1: Fast subject/sender pre-scan.
///
/// Scans messages in batches of [_phase1BatchSize], checking subject and/or
/// sender against keywords. Returns message IDs of candidates that match,
/// along with writing their metadata to session chunks.
Future<List<String>> _runPhase1({
  required List<String> allIds,
  required String account,
  required String mailbox,
  required List<String> keywords,
  required String searchOperator,
  required String searchField,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final batches = batchList(allIds, _phase1BatchSize);
  final candidateIds = <String>[];
  var scanned = 0;

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  for (var i = 0; i < batches.length; i++) {
    // Check for cancellation between batches
    if (session.isComplete) return candidateIds;

    final batch = batches[i];
    final idSet = buildMessageIdSet(batch);

    // Build keyword search condition for subject/sender
    final condition = _buildSubjectSenderCondition(
      keywords: keywords,
      searchOperator: searchOperator,
      searchField: searchField,
    );
    final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to ""
    set targetAccount to account "$escapedAccount"
    set idSet to $idSet

    ${_mailboxLoopStart(mailbox, escapedMailbox)}
                    set mailboxMessages to every message of currentMailbox
                    repeat with aMessage in mailboxMessages
                        try
                            set msgId to message id of aMessage
                            if msgId is in idSet then
                                set messageSubject to subject of aMessage
                                set messageSender to sender of aMessage
                                set lowerSubject to my lowercase(messageSubject)
                                set lowerSender to my lowercase(messageSender)
                                if $condition then
                                    set messageDate to date received of aMessage
                                    set outputText to outputText & msgId & "|" & messageSubject & "|" & messageSender & "|" & (messageDate as string) & linefeed
                                end if
                            end if
                        end try
                    end repeat
    ${_mailboxLoopEnd(mailbox)}

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
        if (parts.isNotEmpty) {
          candidateIds.add(parts[0]);
        }
      }
    } catch (e) {
      session.chunks.add('Warning: Phase 1 batch ${i + 1} error: $e\n');
    }

    scanned += batch.length;
    await extra.sendProgress(0,
        message:
            'Phase 1: Scanned $scanned of ${allIds.length} messages, '
            'found ${candidateIds.length} candidates');
  }

  return candidateIds;
}

/// Phase 2: Body content search on candidate IDs.
///
/// Fetches message content in batches of [_phase2BatchSize], checks body
/// against keywords, and writes matching results to session chunks
/// progressively. Returns the total number of matches found.
Future<int> _runPhase2({
  required List<String> candidateIds,
  required String account,
  required String mailbox,
  required List<String> keywords,
  required String searchOperator,
  required String searchField,
  required bool searchBody,
  required int maxResults,
  required int offset,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final batches = batchList(candidateIds, _phase2BatchSize);
  var matchedCount = 0;
  var resultCount = 0;
  var searched = 0;

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  for (var i = 0; i < batches.length; i++) {
    // Check for cancellation and max results between batches
    if (session.isComplete) return matchedCount;
    if (resultCount >= maxResults) break;

    final batch = batches[i];
    final idSet = buildMessageIdSet(batch);

    // Build full search condition (including body)
    final condition = _buildFullSearchCondition(
      keywords: keywords,
      searchOperator: searchOperator,
      searchField: searchField,
      searchBody: searchBody,
    );

    final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to ""
    set targetAccount to account "$escapedAccount"
    set idSet to $idSet

    ${_mailboxLoopStart(mailbox, escapedMailbox)}
                    set mailboxMessages to every message of currentMailbox
                    repeat with aMessage in mailboxMessages
                        try
                            set msgId to message id of aMessage
                            if msgId is in idSet then
                                set messageSubject to subject of aMessage
                                set messageSender to sender of aMessage
                                set lowerSubject to my lowercase(messageSubject)
                                set lowerSender to my lowercase(messageSender)
                                set msgContent to ""
                                try
                                    set msgContent to content of aMessage
                                end try
                                set lowerContent to my lowercase(msgContent)
                                if $condition then
                                    set messageDate to date received of aMessage
                                    set messageRead to read status of aMessage
                                    if messageRead then
                                        set readIndicator to "read"
                                    else
                                        set readIndicator to "unread"
                                    end if
                                    set outputText to outputText & msgId & "|" & readIndicator & "|" & messageSubject & "|" & messageSender & "|" & (messageDate as string) & linefeed
                                end if
                            end if
                        end try
                    end repeat
    ${_mailboxLoopEnd(mailbox)}

    return outputText
end tell
''';

    try {
      final result = await runAppleScript(script);
      final lines = result
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty);

      final batchOutput = StringBuffer();
      for (final line in lines) {
        final parts = line.split('|');
        if (parts.length >= 5) {
          matchedCount++;
          if (matchedCount > offset && resultCount < maxResults) {
            final readIndicator = parts[1] == 'read' ? '✓' : '✉';
            final subject = parts[2];
            final sender = parts[3];
            final date = parts[4];

            batchOutput.writeln('$readIndicator $subject');
            batchOutput.writeln('   From: $sender');
            batchOutput.writeln('   Date: $date');
            batchOutput.writeln('   Mailbox: $mailbox');
            batchOutput.writeln();
            resultCount++;
          }
        }
      }

      // Write batch results to session immediately for progressive polling
      if (batchOutput.isNotEmpty) {
        session.chunks.add(batchOutput.toString());
      }
    } catch (e) {
      session.chunks.add('Warning: Phase 2 batch ${i + 1} error: $e\n');
    }

    searched += batch.length;
    await extra.sendProgress(0,
        message:
            'Phase 2: Searched body of $searched/${candidateIds.length} '
            'candidates, found $matchedCount matches');
  }

  return matchedCount;
}

// ─────────────────────── AppleScript helpers ───────────────────────

/// Builds a subject/sender search condition for Phase 1.
String _buildSubjectSenderCondition({
  required List<String> keywords,
  required String searchOperator,
  required String searchField,
}) {
  final checks = <String>[];
  for (final keyword in keywords) {
    final escaped = escapeAppleScript(keyword.toLowerCase());
    final fieldChecks = <String>[];
    if (searchField == 'all' || searchField == 'subject') {
      fieldChecks.add('lowerSubject contains "$escaped"');
    }
    if (searchField == 'all') {
      // Also check sender in Phase 1 for "all" mode
      fieldChecks.add('lowerSender contains "$escaped"');
    }
    if (fieldChecks.isEmpty) {
      // search_field is "body" — accept everything in Phase 1
      return 'true';
    }
    if (fieldChecks.length == 1) {
      checks.add(fieldChecks.first);
    } else {
      checks.add('(${fieldChecks.join(' or ')})');
    }
  }

  if (checks.isEmpty) return 'true';

  return searchOperator == 'and'
      ? checks.join(' and ')
      : checks.join(' or ');
}

/// Builds the full search condition including body for Phase 2.
String _buildFullSearchCondition({
  required List<String> keywords,
  required String searchOperator,
  required String searchField,
  required bool searchBody,
}) {
  final checks = <String>[];
  for (final keyword in keywords) {
    final escaped = escapeAppleScript(keyword.toLowerCase());
    final fieldChecks = <String>[];
    if (searchField == 'all' || searchField == 'subject') {
      fieldChecks.add('lowerSubject contains "$escaped"');
    }
    if ((searchField == 'all' || searchField == 'body') && searchBody) {
      fieldChecks.add('lowerContent contains "$escaped"');
    }
    if (fieldChecks.isEmpty) return 'true';
    if (fieldChecks.length == 1) {
      checks.add(fieldChecks.first);
    } else {
      checks.add('(${fieldChecks.join(' or ')})');
    }
  }

  if (checks.isEmpty) return 'true';

  return searchOperator == 'and'
      ? checks.join(' and ')
      : checks.join(' or ');
}

/// Generates the AppleScript mailbox loop start for batch scripts.
///
/// For "All" mailbox: loops all mailboxes with folder skipping.
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
            set mailboxName to name of currentMailbox
            if true then''';
  }
}

/// Generates the AppleScript mailbox loop end.
String _mailboxLoopEnd(String mailbox) {
  return '''
                end if
            end try
        end repeat''';
}

