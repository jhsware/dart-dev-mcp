// Batched handlers for cross-account search operations.
//
// These operations iterate across multiple accounts and/or mailboxes,
// making them naturally slow. Batching provides progress visibility
// and cancellation support via account-level and batch-level progress.
//
// Operations:
// - search-by-sender: Find emails from a sender across accounts/mailboxes
// - search-all-accounts: Cross-account unified search (INBOX only)
// - get-newsletters: Newsletter detection across accounts (INBOX only)

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../core.dart';
import '../batch_helpers.dart';
import '../constants.dart';

/// Batch size for cross-account searches (subject/sender only).
const _batchSize = 200;

/// Batched search-by-sender handler.
///
/// Iterates accounts (single or all), fetches message IDs per mailbox,
/// then processes in batches checking sender match.
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

  final escapedSender = escapeAppleScript(sender.toLowerCase());

  session.chunks.add(
    'EMAILS FROM SENDER: $sender\n'
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n',
  );

  // Determine accounts to search
  List<String> accounts;
  if (account != null) {
    accounts = [account];
  } else {
    await extra.sendProgress(0, message: 'Fetching account list...');
    accounts = await fetchAccountNames();
  }

  var matchedCount = 0;
  var resultCount = 0;

  for (var acctIdx = 0; acctIdx < accounts.length; acctIdx++) {
    if (session.isComplete) return;
    if (resultCount >= maxResults) break;

    final acctName = accounts[acctIdx];
    await extra.sendProgress(0,
        message:
            'Searching account ${acctIdx + 1}/${accounts.length}: $acctName');

    List<String> allIds;
    try {
      allIds = await fetchMessageIds(
        account: acctName,
        mailbox: mailbox,
        daysBack: daysBack,
      );
    } catch (e) {
      session.chunks
          .add('⚠ Error accessing account $acctName: $e\n');
      continue;
    }

    if (allIds.isEmpty) continue;

    final escapedAccount = escapeAppleScript(acctName);
    final escapedMailbox = escapeAppleScript(mailbox);
    final batches = batchList(allIds, _batchSize);

    for (var i = 0; i < batches.length; i++) {
      if (session.isComplete) return;
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
                                set messageSender to sender of aMessage
                                set lowerSender to my lowercase(messageSender)
                                if lowerSender contains "$escapedSender" then
                                    set messageSubject to subject of aMessage
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
        final batchOutput = StringBuffer();
        for (final line in _parseLines(result)) {
          final parts = line.split('|');
          if (parts.length >= 6) {
            matchedCount++;
            if (matchedCount > offset && resultCount < maxResults) {
              final readIndicator = parts[1] == 'read' ? '✓' : '✉';
              batchOutput.writeln('$readIndicator ${parts[2]}');
              batchOutput.writeln('   From: ${parts[3]}');
              batchOutput.writeln('   Date: ${parts[4]}');
              batchOutput.writeln('   Account: $acctName');
              batchOutput.writeln('   Mailbox: ${parts[5]}');
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
        session.chunks.add('Warning: Batch error for $acctName: $e\n');
      }
    }
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
/// Iterates all accounts, searches INBOX for each with optional
/// subject/sender filters. Results are grouped by account.
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

  await extra.sendProgress(0, message: 'Fetching account list...');
  final accounts = await fetchAccountNames();

  var totalResults = 0;

  for (var acctIdx = 0; acctIdx < accounts.length; acctIdx++) {
    if (session.isComplete) return;
    if (totalResults >= maxResults) break;

    final acctName = accounts[acctIdx];
    await extra.sendProgress(0,
        message:
            'Searching account ${acctIdx + 1}/${accounts.length}: $acctName');

    List<String> allIds;
    try {
      allIds = await fetchMessageIds(
        account: acctName,
        mailbox: 'INBOX',
        daysBack: daysBack,
      );
    } catch (e) {
      continue; // Skip accounts with errors
    }

    if (allIds.isEmpty) continue;

    final escapedAccount = escapeAppleScript(acctName);

    // Build AppleScript filter conditions
    final filterParts = <String>[];
    if (subjectKeyword != null) {
      final escaped = escapeAppleScript(subjectKeyword.toLowerCase());
      filterParts.add('lowerSubject contains "$escaped"');
    }
    if (sender != null) {
      final escaped = escapeAppleScript(sender.toLowerCase());
      filterParts.add('lowerSender contains "$escaped"');
    }
    final filterCondition =
        filterParts.isEmpty ? 'true' : filterParts.join(' and ');

    final batches = batchList(allIds, _batchSize);
    for (var i = 0; i < batches.length; i++) {
      if (session.isComplete) return;
      if (totalResults >= maxResults) break;

      final batch = batches[i];
      final idSet = buildMessageIdSet(batch);

      final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to ""
    set targetAccount to account "$escapedAccount"
    set idSet to $idSet

    ${_mailboxLoopStart('INBOX', 'INBOX')}
                    set mailboxMessages to every message of currentMailbox
                    repeat with aMessage in mailboxMessages
                        try
                            set msgId to message id of aMessage
                            if msgId is in idSet then
                                set messageSubject to subject of aMessage
                                set messageSender to sender of aMessage
                                set lowerSubject to my lowercase(messageSubject)
                                set lowerSender to my lowercase(messageSender)
                                if $filterCondition then
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
    ${_mailboxLoopEnd()}

    return outputText
end tell
''';

      try {
        final result = await runAppleScript(script);
        final batchOutput = StringBuffer();
        for (final line in _parseLines(result)) {
          final parts = line.split('|');
          if (parts.length >= 5) {
            totalResults++;
            if (totalResults <= maxResults) {
              final readStatus = parts[1] == 'read' ? 'Read' : 'UNREAD';
              batchOutput.writeln('Account: $acctName');
              batchOutput.writeln('Subject: ${parts[2]}');
              batchOutput.writeln('From: ${parts[3]}');
              batchOutput.writeln('Date: ${parts[4]}');
              batchOutput.writeln('Status: $readStatus');
              batchOutput.writeln('ID: ${parts[0]}');
              batchOutput.writeln('\n---');
            }
          }
        }
        if (batchOutput.isNotEmpty) {
          session.chunks.add(batchOutput.toString());
        }
      } catch (e) {
        // Skip batch errors silently
      }
    }
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
/// Detects newsletters using sender pattern matching across all accounts.
/// Only searches INBOX mailboxes.
Future<void> runBatchedGetNewsletters({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final account = args['account'] as String?;
  final daysBack = args['days_back'] as int? ?? 7;
  final maxResults = args['max_results'] as int? ?? 25;

  // Build newsletter pattern conditions
  final platformChecks = newsletterPlatformPatterns
      .map((p) => 'lowerSender contains "$p"')
      .join(' or ');
  final keywordChecks = newsletterKeywordPatterns
      .map((p) => 'lowerSender contains "$p"')
      .join(' or ');
  final newsletterCondition = '($platformChecks) or ($keywordChecks)';

  session.chunks.add(
    '📰 NEWSLETTER DETECTION\n'
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n',
  );

  // Determine accounts
  List<String> accounts;
  if (account != null) {
    accounts = [account];
  } else {
    await extra.sendProgress(0, message: 'Fetching account list...');
    accounts = await fetchAccountNames();
  }

  var resultCount = 0;

  for (var acctIdx = 0; acctIdx < accounts.length; acctIdx++) {
    if (session.isComplete) return;
    if (resultCount >= maxResults) break;

    final acctName = accounts[acctIdx];
    await extra.sendProgress(0,
        message:
            'Scanning account ${acctIdx + 1}/${accounts.length}: $acctName');

    List<String> allIds;
    try {
      allIds = await fetchMessageIds(
        account: acctName,
        mailbox: 'INBOX',
        daysBack: daysBack,
      );
    } catch (e) {
      continue;
    }

    if (allIds.isEmpty) continue;

    final escapedAccount = escapeAppleScript(acctName);

    final batches = batchList(allIds, _batchSize);
    for (var i = 0; i < batches.length; i++) {
      if (session.isComplete) return;
      if (resultCount >= maxResults) break;

      final batch = batches[i];
      final idSet = buildMessageIdSet(batch);

      final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to ""
    set targetAccount to account "$escapedAccount"
    set idSet to $idSet

    ${_mailboxLoopStart('INBOX', 'INBOX')}
                    set mailboxMessages to every message of currentMailbox
                    repeat with aMessage in mailboxMessages
                        try
                            set msgId to message id of aMessage
                            if msgId is in idSet then
                                set messageSender to sender of aMessage
                                set lowerSender to my lowercase(messageSender)
                                if $newsletterCondition then
                                    set messageSubject to subject of aMessage
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
    ${_mailboxLoopEnd()}

    return outputText
end tell
''';

      try {
        final result = await runAppleScript(script);
        final batchOutput = StringBuffer();
        for (final line in _parseLines(result)) {
          final parts = line.split('|');
          if (parts.length >= 5) {
            resultCount++;
            if (resultCount <= maxResults) {
              final readIndicator = parts[1] == 'read' ? '✓' : '✉';
              batchOutput.writeln('$readIndicator ${parts[2]}');
              batchOutput.writeln('   From: ${parts[3]}');
              batchOutput.writeln('   Date: ${parts[4]}');
              batchOutput.writeln('   Account: $acctName');
              batchOutput.writeln('   ID: ${parts[0]}');
              batchOutput.writeln();
            }
          }
        }
        if (batchOutput.isNotEmpty) {
          session.chunks.add(batchOutput.toString());
        }
      } catch (e) {
        // Skip batch errors silently
      }
    }
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

/// Parses AppleScript output into non-empty trimmed lines.
Iterable<String> _parseLines(String result) {
  return result.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
}

/// Generates the AppleScript mailbox loop start for batch scripts.
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
