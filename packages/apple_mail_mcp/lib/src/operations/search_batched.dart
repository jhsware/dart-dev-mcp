// Batched handlers for search-emails and multi-search operations.
//
// Single-phase batching: fetch message IDs, then process in batches
// of 200 with subject/sender matching. Unlike search-email-content,
// these operations don't need body content so a single phase suffices.
//
// Each batch writes results to session chunks progressively, enabling
// polling via get_output. Cancellation is checked between batches.

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../core.dart';
import '../batch_helpers.dart';

/// Batch size for subject/sender searches (fast, so large batches).
const _batchSize = 200;

/// Batched search-emails handler.
///
/// Fetches message IDs, then processes in batches checking subject/sender
/// against query keywords with support for all existing filters:
/// has_attachments, read_status, subject_keyword, sender.
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

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // Write header chunk
  session.chunks.add(
    'SEARCH RESULTS\n\n'
    'Searching in: $mailbox\n'
    'Account: $account\n\n',
  );

  // Fetch message IDs with date filtering
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
      'FOUND: 0 matching email(s), showing 0 (offset: $offset)\n'
      '========================================\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'search-emails completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${allIds.length} messages to search');

  // Build query condition for AppleScript
  String queryCondition = '';
  if (query != null) {
    final keywords =
        query.split(' ').where((k) => k.trim().isNotEmpty).toList();
    queryCondition = _buildQueryCondition(
      keywords: keywords,
      searchOperator: searchOperator,
      searchField: searchField,
    );
  }

  // Build additional filter conditions
  final filterConditions = <String>[];
  if (subjectKeyword != null) {
    filterConditions.add(
        'lowerSubject contains "${escapeAppleScript(subjectKeyword.toLowerCase())}"');
  }
  if (sender != null) {
    filterConditions.add(
        'lowerSender contains "${escapeAppleScript(sender.toLowerCase())}"');
  }
  if (hasAttachments == true) {
    filterConditions.add('(count of mail attachments of aMessage) > 0');
  } else if (hasAttachments == false) {
    filterConditions.add('(count of mail attachments of aMessage) = 0');
  }
  if (readStatus == 'read') {
    filterConditions.add('messageRead is true');
  } else if (readStatus == 'unread') {
    filterConditions.add('messageRead is false');
  }

  // Combine: (query condition) AND (filter conditions)
  String conditionStr;
  if (queryCondition.isNotEmpty && filterConditions.isNotEmpty) {
    conditionStr = '($queryCondition) and ${filterConditions.join(' and ')}';
  } else if (queryCondition.isNotEmpty) {
    conditionStr = queryCondition;
  } else if (filterConditions.isNotEmpty) {
    conditionStr = filterConditions.join(' and ');
  } else {
    conditionStr = 'true';
  }

  // Process in batches
  final batches = batchList(allIds, _batchSize);
  var matchedCount = 0;
  var resultCount = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return; // cancelled
    if (resultCount >= maxResults) break;

    final batch = batches[i];
    final idSet = buildMessageIdSet(batch);

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
                                set messageDate to date received of aMessage
                                set messageRead to read status of aMessage
                                set lowerSubject to my lowercase(messageSubject)
                                set lowerSender to my lowercase(messageSender)
                                if $conditionStr then
                                    if messageRead then
                                        set readIndicator to "read"
                                    else
                                        set readIndicator to "unread"
                                    end if
                                    set mailboxName to name of currentMailbox
                                    set outputText to outputText & msgId & "|" & readIndicator & "|" & messageSubject & "|" & messageSender & "|" & (messageDate as string) & "|" & mailboxName & linefeed
                                end if
                            end if
                        end try
                    end repeat
    ${_mailboxLoopEnd()}

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
        if (parts.length >= 6) {
          matchedCount++;
          if (matchedCount > offset && resultCount < maxResults) {
            final readIndicator = parts[1] == 'read' ? '✓' : '✉';
            final subject = parts[2];
            final senderVal = parts[3];
            final date = parts[4];
            final mailboxName = parts[5];

            batchOutput.writeln('$readIndicator $subject');
            batchOutput.writeln('   From: $senderVal');
            batchOutput.writeln('   Date: $date');
            batchOutput.writeln('   Mailbox: $mailboxName');
            batchOutput.writeln('   ID: ${parts[0]}');
            batchOutput.writeln();
            resultCount++;
          }
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
        message: 'Scanned $scanned of ${allIds.length} messages, '
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
/// Similar to search-emails but with multiple comma-separated query groups.
/// AppleScript pre-filters with an OR of all keywords, then Dart-side
/// tagging determines which groups matched each result.
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

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  final useSubject = searchField == 'all' || searchField == 'subject';
  final useSender = searchField == 'all' || searchField == 'sender';

  // Parse query groups: "invoice faktura, receipt kvitto" →
  // [["invoice", "faktura"], ["receipt", "kvitto"]]
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

  // Collect all unique keywords for AppleScript OR condition
  final allKeywords = <String>{};
  for (final group in groups) {
    allKeywords.addAll(group.map((k) => k.toLowerCase()));
  }

  final keywordChecks = <String>[];
  for (final keyword in allKeywords) {
    final escaped = escapeAppleScript(keyword);
    if (useSubject) keywordChecks.add('lowerSubject contains "$escaped"');
    if (useSender) keywordChecks.add('lowerSender contains "$escaped"');
  }
  final anyKeywordCondition =
      keywordChecks.isNotEmpty ? keywordChecks.join(' or ') : 'true';

  // Write header chunk
  session.chunks.add(
    'MULTI-SEARCH RESULTS\n'
    'Query groups: $queries\n'
    'Account: $account\n'
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n',
  );

  // Fetch message IDs
  await extra.sendProgress(0, message: 'Fetching message IDs...');
  final allIds = await fetchMessageIds(
    account: account,
    mailbox: mailbox,
    daysBack: daysBack,
  );

  if (allIds.isEmpty) {
    session.chunks.add(
      '========================================\n'
      'FOUND: 0 matching email(s), showing 0 (offset: $offset)\n'
      'Query groups searched: ${groups.length}\n'
      '========================================\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'multi-search completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${allIds.length} messages to search');

  // Process in batches
  final batches = batchList(allIds, _batchSize);
  var matchedCount = 0;
  var resultCount = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return; // cancelled
    if (resultCount >= maxResults) break;

    final batch = batches[i];
    final idSet = buildMessageIdSet(batch);

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
                                if $anyKeywordCondition then
                                    set messageDate to date received of aMessage
                                    set messageRead to read status of aMessage
                                    if messageRead then
                                        set readIndicator to "read"
                                    else
                                        set readIndicator to "unread"
                                    end if
                                    set mailboxName to name of currentMailbox
                                    set outputText to outputText & msgId & "|" & readIndicator & "|" & messageSubject & "|" & messageSender & "|" & (messageDate as string) & "|" & mailboxName & linefeed
                                end if
                            end if
                        end try
                    end repeat
    ${_mailboxLoopEnd()}

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
        if (parts.length >= 6) {
          matchedCount++;
          if (matchedCount > offset && resultCount < maxResults) {
            final readIndicator = parts[1] == 'read' ? '✓' : '✉';
            final subject = parts[2];
            final senderVal = parts[3];
            final date = parts[4];
            final mailboxName = parts[5];

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
            batchOutput.writeln('   Date: $date');
            batchOutput.writeln('   Mailbox: $mailboxName');
            batchOutput.writeln(
                '   Matched: ${matchedGroups.join(' ')}');
            batchOutput.writeln('   ID: ${parts[0]}');
            batchOutput.writeln();
            resultCount++;
          }
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
        message: 'Scanned $scanned of ${allIds.length} messages, '
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

// ─────────────────────── AppleScript helpers ───────────────────────

/// Builds an AppleScript condition for keyword search across subject/sender.
String _buildQueryCondition({
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
    if (searchField == 'all' || searchField == 'sender') {
      fieldChecks.add('lowerSender contains "$escaped"');
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
