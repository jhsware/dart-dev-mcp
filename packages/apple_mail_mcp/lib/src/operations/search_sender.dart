// Sender-related search operations: finding emails by sender.
//
// Split from search.dart for maintainability.

import 'package:mcp_dart/mcp_dart.dart';

import '../core.dart';
import '../constants.dart';

/// Handles the search-by-sender operation.
///
/// Finds emails from a specific sender with case-insensitive matching.
Future<CallToolResult> handleSearchBySender(
    Map<String, dynamic> args) async {
  final sender = args['sender'] as String?;
  if (sender == null) {
    return actionableError(
      'sender parameter is required for search-by-sender.',
      'Provide a sender name or email address to search for.',
    );
  }

  final account = args['account'] as String?;
  final daysBack = args['days_back'] as int? ?? 30;
  final maxResults = args['max_results'] as int? ?? 20;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final offset = args['offset'] as int? ?? 0;


  final escapedSender = escapeAppleScript(sender);
  final escapedMailbox = escapeAppleScript(mailbox);
  final searchAllMailboxes = mailbox == 'All';

  final dateFilterScript =
      daysBack > 0 ? 'set targetDate to (current date) - ($daysBack * days)' : '';
  final dateCheck = daysBack > 0 ? 'and messageDate > targetDate' : '';

  String mailboxLoopStart;
  String mailboxLoopEnd;
  if (searchAllMailboxes) {
    mailboxLoopStart = '''
                set accountMailboxes to every mailbox of anAccount
                repeat with aMailbox in accountMailboxes
                    set mailboxName to name of aMailbox
                    if mailboxName is not in {"Trash", "Junk", "Junk Email", "Deleted Items", "Deleted Messages", "Spam", "Drafts", "Sent", "Sent Items", "Sent Messages", "Sent Mail", "All Mail", "Bin"} then
''';
    mailboxLoopEnd = '''
                        if resultCount >= $maxResults then exit repeat
                    end if
                end repeat
''';
  } else {
    mailboxLoopStart = '''
                try
                    set aMailbox to mailbox "$escapedMailbox" of anAccount
                on error
                    if "$escapedMailbox" is "INBOX" then
                        set aMailbox to mailbox "Inbox" of anAccount
                    else
                        error "Mailbox not found: $escapedMailbox"
                    end if
                end try
                set mailboxName to name of aMailbox
                if true then
''';
    mailboxLoopEnd = '''
                end if
''';
  }

  String accountLoopStart;
  String accountLoopEnd;
  if (account != null) {
    final escapedAccount = escapeAppleScript(account);
    accountLoopStart = '''
        set anAccount to account "$escapedAccount"
        set accountName to name of anAccount
        repeat 1 times
''';
    accountLoopEnd = '''
        end repeat
''';
  } else {
    accountLoopStart = '''
        set allAccounts to every account
        repeat with anAccount in allAccounts
            set accountName to name of anAccount
''';
    accountLoopEnd = '''
            if resultCount >= $maxResults then exit repeat
        end repeat
''';
  }

  final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to "EMAILS FROM SENDER: $escapedSender" & return
    set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return & return
    set matchedCount to 0
    set resultCount to 0


    $dateFilterScript

    $accountLoopStart

        try
            $mailboxLoopStart

                    set mailboxMessages to every message of aMailbox

                    repeat with aMessage in mailboxMessages
                        if resultCount >= $maxResults then exit repeat

                        try
                            set messageSender to sender of aMessage
                            set messageDate to date received of aMessage

                            set lowerSender to my lowercase(messageSender)
                            set lowerSearch to my lowercase("$escapedSender")

                            if lowerSender contains lowerSearch $dateCheck then
                                set matchedCount to matchedCount + 1
                                if matchedCount > $offset then
                                    set messageSubject to subject of aMessage
                                    set messageRead to read status of aMessage

                                    if messageRead then
                                        set readIndicator to "✓"
                                    else
                                        set readIndicator to "✉"
                                    end if

                                    set outputText to outputText & readIndicator & " " & messageSubject & return
                                    set outputText to outputText & "   From: " & messageSender & return
                                    set outputText to outputText & "   Date: " & (messageDate as string) & return
                                    set outputText to outputText & "   Account: " & accountName & return
                                    set outputText to outputText & "   Mailbox: " & mailboxName & return
                                    set outputText to outputText & "   ID: " & (message id of aMessage) & return
                                    set outputText to outputText & return
                                    set resultCount to resultCount + 1
                                end if

                            end if
                        end try
                    end repeat

            $mailboxLoopEnd

        on error errMsg
            set outputText to outputText & "⚠ Error accessing mailboxes for " & accountName & ": " & errMsg & return
        end try

    $accountLoopEnd

    set outputText to outputText & "========================================" & return
    set outputText to outputText & "FOUND: " & matchedCount & " matching email(s) from sender, showing " & resultCount & " (offset: $offset)" & return
    set outputText to outputText & "========================================" & return

    return outputText
end tell
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Handles the get-recent-from-sender operation.
///
/// Gets recent emails from a sender with human-friendly time filters.
Future<CallToolResult> handleGetRecentFromSender(
    Map<String, dynamic> args) async {
  final sender = args['sender'] as String?;
  if (sender == null) {
    return actionableError(
      'sender parameter is required for get-recent-from-sender.',
      'Provide a sender name or email address to search for.',
    );
  }

  final account = args['account'] as String?;
  final timeRange = args['time_range'] as String? ?? 'week';
  final maxResults = args['max_results'] as int? ?? 15;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';

  final daysBack = timeRanges[timeRange.toLowerCase()] ?? 7;
  final isYesterday = timeRange.toLowerCase() == 'yesterday';

  final escapedSender = escapeAppleScript(sender);
  final escapedMailbox = escapeAppleScript(mailbox);
  final searchAllMailboxes = mailbox == 'All';

  String dateFilter = '';
  String dateCheck = '';
  if (daysBack > 0) {
    dateFilter = 'set cutoffDate to (current date) - ($daysBack * days)';
    if (isYesterday) {
      dateFilter += '''

            set todayStart to (current date) - (time of (current date))
            set yesterdayStart to todayStart - (1 * days)
''';
      dateCheck =
          ' and messageDate >= yesterdayStart and messageDate < todayStart';
    } else {
      dateCheck = ' and messageDate > cutoffDate';
    }
  }

  String mailboxLoopStart;
  String mailboxLoopEnd;
  if (searchAllMailboxes) {
    mailboxLoopStart = '''
                set accountMailboxes to every mailbox of anAccount
                repeat with aMailbox in accountMailboxes
                    try
                        set mailboxName to name of aMailbox
                        if mailboxName is not in {"Trash", "Junk", "Junk Email", "Deleted Items", "Deleted Messages", "Spam", "Drafts", "Sent", "Sent Items", "Sent Messages", "Sent Mail", "All Mail", "Bin"} then
''';
    mailboxLoopEnd = '''
                        end if
                    end try
                    if resultCount >= $maxResults then exit repeat
                end repeat
''';
  } else {
    mailboxLoopStart = '''
                try
                    set aMailbox to mailbox "$escapedMailbox" of anAccount
                on error
                    if "$escapedMailbox" is "INBOX" then
                        set aMailbox to mailbox "Inbox" of anAccount
                    else
                        error "Mailbox not found: $escapedMailbox"
                    end if
                end try
                set mailboxName to name of aMailbox
                if true then
''';
    mailboxLoopEnd = '''
                end if
''';
  }

  String accountLoopStart;
  String accountLoopEnd;
  if (account != null) {
    final escapedAccount = escapeAppleScript(account);
    accountLoopStart = '''
        set anAccount to account "$escapedAccount"
        set accountName to name of anAccount
        repeat 1 times
''';
    accountLoopEnd = '''
        end repeat
''';
  } else {
    accountLoopStart = '''
        set allAccounts to every account
        repeat with anAccount in allAccounts
            set accountName to name of anAccount
''';
    accountLoopEnd = '''
            if resultCount >= $maxResults then exit repeat
        end repeat
''';
  }

  final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to "📧 EMAILS FROM: $escapedSender" & return
    set outputText to outputText & "⏰ Time range: $timeRange" & return
    set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return & return
    set resultCount to 0
    $dateFilter

    $accountLoopStart

        try
            $mailboxLoopStart

                        set mailboxMessages to every message of aMailbox
                        repeat with aMessage in mailboxMessages
                            if resultCount >= $maxResults then exit repeat
                            try
                                set messageSender to sender of aMessage
                                set messageDate to date received of aMessage
                                set lowerSender to my lowercase(messageSender)
                                set lowerSearch to my lowercase("$escapedSender")
                                if lowerSender contains lowerSearch$dateCheck then
                                    set messageSubject to subject of aMessage
                                    set messageRead to read status of aMessage
                                    if messageRead then
                                        set readIndicator to "✓"
                                    else
                                        set readIndicator to "✉"
                                    end if
                                    set outputText to outputText & readIndicator & " " & messageSubject & return
                                    set outputText to outputText & "   From: " & messageSender & return
                                    set outputText to outputText & "   Date: " & (messageDate as string) & return
                                    set outputText to outputText & "   Account: " & accountName & return
                                    set outputText to outputText & "   ID: " & (message id of aMessage) & return
                                    set outputText to outputText & return
                                    set resultCount to resultCount + 1
                                end if
                            end try
                        end repeat

            $mailboxLoopEnd

        end try

    $accountLoopEnd

    set outputText to outputText & "========================================" & return
    set outputText to outputText & "FOUND: " & resultCount & " email(s) from sender" & return
    set outputText to outputText & "========================================" & return
    return outputText
end tell
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Returns the dispatch map for sender-related search operations.
Map<String, Future<CallToolResult> Function(Map<String, dynamic>)>
    getSenderSearchOperations() {
  return {
    'search-by-sender': handleSearchBySender,
    'get-recent-from-sender': handleGetRecentFromSender,
  };
}
