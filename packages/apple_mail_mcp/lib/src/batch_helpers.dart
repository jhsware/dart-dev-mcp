// Batch helpers for Apple Mail MCP operations.
//
// Provides utilities for fetching message IDs in bulk and splitting
// work into batches for progressive processing with cancellation support.

import 'core.dart';

/// Splits a list into batches of the given size.
///
/// Example: `batchList([1,2,3,4,5], 2)` → `[[1,2], [3,4], [5]]`
List<List<T>> batchList<T>(List<T> items, int batchSize) {
  final batches = <List<T>>[];
  for (var i = 0; i < items.length; i += batchSize) {
    final end = (i + batchSize < items.length) ? i + batchSize : items.length;
    batches.add(items.sublist(i, end));
  }
  return batches;
}

/// Fetches message IDs from a mailbox, optionally filtered by date.
///
/// Returns a list of Apple Mail message ID strings. Message IDs are stable
/// identifiers that don't shift when new mail arrives, making them safe
/// to use across multiple AppleScript invocations.
///
/// When [mailbox] is "All", searches all mailboxes except system folders
/// (Trash, Junk, Sent, Drafts, etc.).
Future<List<String>> fetchMessageIds({
  required String account,
  required String mailbox,
  int daysBack = 0,
  String? startDate,
  String? endDate,
}) async {
  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // Build date filter setup and check
  final dateSetup = StringBuffer();
  final dateChecks = <String>[];

  if (daysBack > 0) {
    dateSetup.writeln(
        '    set cutoffDate to (current date) - ($daysBack * days)');
    dateChecks.add('messageDate > cutoffDate');
  }

  if (startDate != null) {
    final parts = startDate.split('-');
    dateSetup.writeln('''
    set startDateObj to current date
    set year of startDateObj to ${parts[0]}
    set month of startDateObj to ${parts[1]}
    set day of startDateObj to ${parts[2]}
    set hours of startDateObj to 0
    set minutes of startDateObj to 0
    set seconds of startDateObj to 0''');
    dateChecks.add('messageDate >= startDateObj');
  }

  if (endDate != null) {
    final parts = endDate.split('-');
    dateSetup.writeln('''
    set endDateObj to current date
    set year of endDateObj to ${parts[0]}
    set month of endDateObj to ${parts[1]}
    set day of endDateObj to ${parts[2]}
    set hours of endDateObj to 23
    set minutes of endDateObj to 59
    set seconds of endDateObj to 59''');
    dateChecks.add('messageDate <= endDateObj');
  }

  final dateCheckCondition =
      dateChecks.isEmpty ? '' : dateChecks.join(' and ');

  final dateCheckScript = dateCheckCondition.isNotEmpty
      ? '''
                        set messageDate to date received of aMessage
                        if not ($dateCheckCondition) then
                            set skipMessage to true
                        end if'''
      : '';

  // Build mailbox resolution script
  String mailboxScript;
  if (mailbox == 'All') {
    mailboxScript = '''
        set searchMailboxes to every mailbox of targetAccount
''';
  } else {
    mailboxScript = '''
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
''';
  }

  // Skip system folders condition (only relevant for "All" mailbox)
  final skipFoldersScript = mailbox == 'All'
      ? '''
                set skipFoldersList to {"Trash", "Junk", "Junk Email", "Deleted Items", "Sent", "Sent Items", "Sent Messages", "Drafts", "Spam", "Deleted Messages"}
                set shouldSkipFolder to false
                repeat with skipFolder in skipFoldersList
                    if mailboxName is skipFolder then
                        set shouldSkipFolder to true
                        exit repeat
                    end if
                end repeat
                if shouldSkipFolder then'''
      : 'if false then -- no folder skip needed';

  final script = '''
tell application "Mail"
    set idList to ""
${dateSetup.toString()}

    try
        set targetAccount to account "$escapedAccount"
$mailboxScript

        repeat with currentMailbox in searchMailboxes
            try
                set mailboxName to name of currentMailbox
                $skipFoldersScript
                    -- skip this folder
                else
                    set mailboxMessages to every message of currentMailbox
                    repeat with aMessage in mailboxMessages
                        try
                            set skipMessage to false
$dateCheckScript
                            if not skipMessage then
                                set msgId to message id of aMessage
                                set idList to idList & msgId & linefeed
                            end if
                        end try
                    end repeat
                end if
            end try
        end repeat

    on error errMsg
        error "ERROR:" & errMsg
    end try

    return idList
end tell
''';

  final result = await runAppleScript(script);
  if (result.startsWith('ERROR:')) {
    throw Exception(result.substring(6));
  }

  return result
      .split('\n')
      .map((id) => id.trim())
      .where((id) => id.isNotEmpty)
      .toList();
}

/// Builds an AppleScript set literal containing the given message IDs.
///
/// Returns a string like `{"id1", "id2", "id3"}` for use in
/// AppleScript `is in` conditions.
String buildMessageIdSet(List<String> messageIds) {
  final escaped = messageIds.map((id) => '"${escapeAppleScript(id)}"');
  return '{${escaped.join(', ')}}';
}

/// Fetches the list of account names from Apple Mail.
///
/// Returns account names as strings, used for cross-account operations
/// that need to iterate all accounts.
Future<List<String>> fetchAccountNames() async {
  final script = '''
tell application "Mail"
    set acctNames to ""
    set allAccounts to every account
    repeat with acct in allAccounts
        set acctNames to acctNames & name of acct & linefeed
    end repeat
    return acctNames
end tell
''';

  final result = await runAppleScript(script);
  return result
      .split('\n')
      .map((n) => n.trim())
      .where((n) => n.isNotEmpty)
      .toList();
}