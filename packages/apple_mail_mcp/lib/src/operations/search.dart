// Search operations: finding and filtering emails.
//
// Ported from Python apple-mail-mcp/apple_mail_mcp/tools/search.py.
// All operations are read-only.

import 'package:mcp_dart/mcp_dart.dart';

import '../core.dart';
import '../constants.dart';

/// Handles the get-email-with-content operation.
///
/// Searches by subject keyword and returns with content preview.
Future<CallToolResult> handleGetEmailWithContent(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return CallToolResult.fromContent(
      [TextContent(text: 'Error: account parameter is required')],
    );
  }

  final subjectKeyword = args['subject_keyword'] as String?;
  if (subjectKeyword == null) {
    return CallToolResult.fromContent(
      [
        TextContent(text: 'Error: subject_keyword parameter is required')
      ],
    );
  }

  final maxResults = args['max_results'] as int? ?? 5;
  final maxContentLength = args['max_content_length'] as int? ?? 300;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';

  final escapedKeyword = escapeAppleScript(subjectKeyword);
  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  String mailboxScript;
  String searchLocation;
  if (mailbox == 'All') {
    mailboxScript = '''
            set allMailboxes to every mailbox of targetAccount
            set searchMailboxes to allMailboxes
''';
    searchLocation = 'all mailboxes';
  } else {
    mailboxScript = '''
            try
                set searchMailbox to mailbox "$escapedMailbox" of targetAccount
            on error
                if "$escapedMailbox" is "INBOX" then
                    set searchMailbox to mailbox "Inbox" of targetAccount
                else
                    error "Mailbox not found: $escapedMailbox"
                end if
            end try
            set searchMailboxes to {searchMailbox}
''';
    searchLocation = mailbox;
  }

  final contentLimitCheck = maxContentLength > 0
      ? 'if $maxContentLength > 0 and length of cleanText > $maxContentLength then\n                                    set contentPreview to text 1 thru $maxContentLength of cleanText & "..."\n                                else\n                                    set contentPreview to cleanText\n                                end if'
      : 'set contentPreview to cleanText';

  final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to "SEARCH RESULTS FOR: $escapedKeyword" & return
    set outputText to outputText & "Searching in: $searchLocation" & return & return
    set resultCount to 0

    try
        set targetAccount to account "$escapedAccount"
        $mailboxScript

        repeat with currentMailbox in searchMailboxes
            set mailboxMessages to every message of currentMailbox
            set mailboxName to name of currentMailbox

            repeat with aMessage in mailboxMessages
                if resultCount >= $maxResults then exit repeat

                try
                    set messageSubject to subject of aMessage

                    set lowerSubject to my lowercase(messageSubject)
                    set lowerKeyword to my lowercase("$escapedKeyword")

                    if lowerSubject contains lowerKeyword then
                        set messageSender to sender of aMessage
                        set messageDate to date received of aMessage
                        set messageRead to read status of aMessage

                        if messageRead then
                            set readIndicator to "✓"
                        else
                            set readIndicator to "✉"
                        end if

                        set outputText to outputText & readIndicator & " " & messageSubject & return
                        set outputText to outputText & "   From: " & messageSender & return
                        set outputText to outputText & "   Date: " & (messageDate as string) & return
                        set outputText to outputText & "   Mailbox: " & mailboxName & return

                        try
                            set msgContent to content of aMessage
                            set AppleScript's text item delimiters to {return, linefeed}
                            set contentParts to text items of msgContent
                            set AppleScript's text item delimiters to " "
                            set cleanText to contentParts as string
                            set AppleScript's text item delimiters to ""

                            $contentLimitCheck

                            set outputText to outputText & "   Content: " & contentPreview & return
                        on error
                            set outputText to outputText & "   Content: [Not available]" & return
                        end try

                        set outputText to outputText & return
                        set resultCount to resultCount + 1
                    end if
                end try
            end repeat
        end repeat

        set outputText to outputText & "========================================" & return
        set outputText to outputText & "FOUND: " & resultCount & " matching email(s)" & return
        set outputText to outputText & "========================================" & return

    on error errMsg
        return "Error: " & errMsg
    end try

    return outputText
end tell
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Handles the search-emails operation.
///
/// Unified advanced search with multiple filter criteria.
Future<CallToolResult> handleSearchEmails(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return CallToolResult.fromContent(
      [TextContent(text: 'Error: account parameter is required')],
    );
  }

  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final subjectKeyword = args['subject_keyword'] as String?;
  final sender = args['sender'] as String?;
  final hasAttachments = args['has_attachments'] as bool?;
  final readStatus = args['read_status'] as String? ?? 'all';
  final includeContent = args['include_content'] as bool? ?? false;
  final maxResults = args['max_results'] as int? ?? 20;

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // Build AppleScript search conditions
  final conditions = <String>[];
  if (subjectKeyword != null) {
    conditions
        .add('messageSubject contains "${escapeAppleScript(subjectKeyword)}"');
  }
  if (sender != null) {
    conditions.add('messageSender contains "${escapeAppleScript(sender)}"');
  }
  if (hasAttachments != null) {
    if (hasAttachments) {
      conditions.add('(count of mail attachments of aMessage) > 0');
    } else {
      conditions.add('(count of mail attachments of aMessage) = 0');
    }
  }
  if (readStatus == 'read') {
    conditions.add('messageRead is true');
  } else if (readStatus == 'unread') {
    conditions.add('messageRead is false');
  }

  final conditionStr =
      conditions.isNotEmpty ? conditions.join(' and ') : 'true';

  final contentScript = includeContent
      ? '''
                                    try
                                        set msgContent to content of aMessage
                                        set AppleScript's text item delimiters to {return, linefeed}
                                        set contentParts to text items of msgContent
                                        set AppleScript's text item delimiters to " "
                                        set cleanText to contentParts as string
                                        set AppleScript's text item delimiters to ""
                                        if length of cleanText > 300 then
                                            set contentPreview to text 1 thru 300 of cleanText & "..."
                                        else
                                            set contentPreview to cleanText
                                        end if
                                        set outputText to outputText & "   Content: " & contentPreview & return
                                    on error
                                        set outputText to outputText & "   Content: [Not available]" & return
                                    end try
'''
      : '';

  String mailboxScript;
  if (mailbox == 'All') {
    mailboxScript = '''
            set allMailboxes to every mailbox of targetAccount
            set searchMailboxes to allMailboxes
''';
  } else {
    mailboxScript = '''
            try
                set searchMailbox to mailbox "$escapedMailbox" of targetAccount
            on error
                if "$escapedMailbox" is "INBOX" then
                    set searchMailbox to mailbox "Inbox" of targetAccount
                else
                    error "Mailbox not found: $escapedMailbox"
                end if
            end try
            set searchMailboxes to {searchMailbox}
''';
  }

  final script = '''
tell application "Mail"
    set outputText to "SEARCH RESULTS" & return & return
    set outputText to outputText & "Searching in: $escapedMailbox" & return
    set outputText to outputText & "Account: $escapedAccount" & return & return
    set resultCount to 0

    try
        set targetAccount to account "$escapedAccount"
        $mailboxScript

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

                if not shouldSkip then
                    set mailboxMessages to every message of currentMailbox

                    repeat with aMessage in mailboxMessages
                        if resultCount >= $maxResults then exit repeat

                        try
                            set messageSubject to subject of aMessage
                            set messageSender to sender of aMessage
                            set messageDate to date received of aMessage
                            set messageRead to read status of aMessage

                            if $conditionStr then
                                set readIndicator to "✉"
                                if messageRead then
                                    set readIndicator to "✓"
                                end if

                                set outputText to outputText & readIndicator & " " & messageSubject & return
                                set outputText to outputText & "   From: " & messageSender & return
                                set outputText to outputText & "   Date: " & (messageDate as string) & return
                                set outputText to outputText & "   Mailbox: " & mailboxName & return

                                $contentScript

                                set outputText to outputText & return
                                set resultCount to resultCount + 1
                            end if
                        end try
                    end repeat
                end if
            on error
                -- Skip mailboxes that throw errors
            end try
        end repeat

        set outputText to outputText & "========================================" & return
        set outputText to outputText & "FOUND: " & resultCount & " matching email(s)" & return
        set outputText to outputText & "========================================" & return

    on error errMsg
        return "Error: " & errMsg
    end try

    return outputText
end tell
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Handles the search-by-sender operation.
///
/// Finds emails from a specific sender with case-insensitive matching.
Future<CallToolResult> handleSearchBySender(
    Map<String, dynamic> args) async {
  final sender = args['sender'] as String?;
  if (sender == null) {
    return CallToolResult.fromContent(
      [TextContent(text: 'Error: sender parameter is required')],
    );
  }

  final account = args['account'] as String?;
  final daysBack = args['days_back'] as int? ?? 30;
  final maxResults = args['max_results'] as int? ?? 20;
  final includeContent = args['include_content'] as bool? ?? true;
  final maxContentLength = args['max_content_length'] as int? ?? 500;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';

  final escapedSender = escapeAppleScript(sender);
  final escapedMailbox = escapeAppleScript(mailbox);
  final searchAllMailboxes = mailbox == 'All';

  final dateFilterScript =
      daysBack > 0 ? 'set targetDate to (current date) - ($daysBack * days)' : '';
  final dateCheck = daysBack > 0 ? 'and messageDate > targetDate' : '';

  final contentScript = includeContent
      ? '''
                                    try
                                        set msgContent to content of aMessage
                                        set AppleScript's text item delimiters to {return, linefeed}
                                        set contentParts to text items of msgContent
                                        set AppleScript's text item delimiters to " "
                                        set cleanText to contentParts as string
                                        set AppleScript's text item delimiters to ""
                                        if $maxContentLength > 0 and length of cleanText > $maxContentLength then
                                            set contentPreview to text 1 thru $maxContentLength of cleanText & "..."
                                        else
                                            set contentPreview to cleanText
                                        end if
                                        set outputText to outputText & "   Content: " & contentPreview & return
                                    on error
                                        set outputText to outputText & "   Content: [Not available]" & return
                                    end try
'''
      : '';

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

                                $contentScript

                                set outputText to outputText & return
                                set resultCount to resultCount + 1
                            end if
                        end try
                    end repeat

            $mailboxLoopEnd

        on error errMsg
            set outputText to outputText & "⚠ Error accessing mailboxes for " & accountName & ": " & errMsg & return
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

/// Handles the search-email-content operation.
///
/// Full-text body content search (slower).
Future<CallToolResult> handleSearchEmailContent(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return CallToolResult.fromContent(
      [TextContent(text: 'Error: account parameter is required')],
    );
  }

  final query = args['query'] as String?;
  if (query == null) {
    return CallToolResult.fromContent(
      [TextContent(text: 'Error: query parameter is required')],
    );
  }

  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final searchBody = args['search_body'] as bool? ?? true;
  final maxResults = args['max_results'] as int? ?? 10;
  final maxContentLength = args['max_content_length'] as int? ?? 600;

  final escapedSearch = escapeAppleScript(query.toLowerCase());
  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // Build search conditions
  final searchConditions = <String>[];
  searchConditions.add('lowerSubject contains "$escapedSearch"');
  if (searchBody) {
    searchConditions.add('lowerContent contains "$escapedSearch"');
  }
  final searchCondition = searchConditions.join(' or ');

  final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to "🔎 CONTENT SEARCH: $escapedSearch" & return
    set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return
    set outputText to outputText & "⚠ Note: Body search is slower - searching $maxResults results max" & return & return
    set resultCount to 0
    try
        set targetAccount to account "$escapedAccount"
        try
            set targetMailbox to mailbox "$escapedMailbox" of targetAccount
        on error
            if "$escapedMailbox" is "INBOX" then
                set targetMailbox to mailbox "Inbox" of targetAccount
            else
                error "Mailbox not found: $escapedMailbox"
            end if
        end try
        set mailboxMessages to every message of targetMailbox
        repeat with aMessage in mailboxMessages
            if resultCount >= $maxResults then exit repeat
            try
                set messageSubject to subject of aMessage
                set msgContent to ""
                try
                    set msgContent to content of aMessage
                end try
                set lowerSubject to my lowercase(messageSubject)
                set lowerContent to my lowercase(msgContent)
                if $searchCondition then
                    set messageSender to sender of aMessage
                    set messageDate to date received of aMessage
                    set messageRead to read status of aMessage
                    if messageRead then
                        set readIndicator to "✓"
                    else
                        set readIndicator to "✉"
                    end if
                    set outputText to outputText & readIndicator & " " & messageSubject & return
                    set outputText to outputText & "   From: " & messageSender & return
                    set outputText to outputText & "   Date: " & (messageDate as string) & return
                    set outputText to outputText & "   Mailbox: $escapedMailbox" & return
                    try
                        set AppleScript's text item delimiters to {return, linefeed}
                        set contentParts to text items of msgContent
                        set AppleScript's text item delimiters to " "
                        set cleanText to contentParts as string
                        set AppleScript's text item delimiters to ""
                        if length of cleanText > $maxContentLength then
                            set contentPreview to text 1 thru $maxContentLength of cleanText & "..."
                        else
                            set contentPreview to cleanText
                        end if
                        set outputText to outputText & "   Content: " & contentPreview & return
                    on error
                        set outputText to outputText & "   Content: [Not available]" & return
                    end try
                    set outputText to outputText & return
                    set resultCount to resultCount + 1
                end if
            end try
        end repeat
        set outputText to outputText & "========================================" & return
        set outputText to outputText & "FOUND: " & resultCount & " email(s) matching \\"$escapedSearch\\"" & return
        set outputText to outputText & "========================================" & return
    on error errMsg
        return "Error: " & errMsg
    end try
    return outputText
end tell
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Handles the get-newsletters operation.
///
/// Detects newsletters using sender pattern matching.
Future<CallToolResult> handleGetNewsletters(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  final daysBack = args['days_back'] as int? ?? 7;
  final maxResults = args['max_results'] as int? ?? 25;
  final includeContent = args['include_content'] as bool? ?? true;
  final maxContentLength = args['max_content_length'] as int? ?? 500;

  final escapedAccount =
      account != null ? escapeAppleScript(account) : null;

  final contentScript = includeContent
      ? '''
                                    try
                                        set msgContent to content of aMessage
                                        set AppleScript's text item delimiters to {return, linefeed}
                                        set contentParts to text items of msgContent
                                        set AppleScript's text item delimiters to " "
                                        set cleanText to contentParts as string
                                        set AppleScript's text item delimiters to ""
                                        if length of cleanText > $maxContentLength then
                                            set contentPreview to text 1 thru $maxContentLength of cleanText & "..."
                                        else
                                            set contentPreview to cleanText
                                        end if
                                        set outputText to outputText & "   Content: " & contentPreview & return
                                    on error
                                        set outputText to outputText & "   Content: [Not available]" & return
                                    end try
'''
      : '';

  final accountFilterStart = escapedAccount != null
      ? 'if accountName is "$escapedAccount" then'
      : '';
  final accountFilterEnd = escapedAccount != null ? 'end if' : '';

  final dateFilter = daysBack > 0
      ? 'set cutoffDate to (current date) - ($daysBack * days)'
      : '';
  final dateCheck = daysBack > 0 ? ' and messageDate > cutoffDate' : '';

  // Build platform pattern check from constants
  final platformChecks = newsletterPlatformPatterns
      .map((p) => 'lowerSender contains "$p"')
      .join(' or ');
  final keywordChecks = newsletterKeywordPatterns
      .map((p) => 'lowerSender contains "$p"')
      .join(' or ');

  final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to "📰 NEWSLETTER DETECTION" & return
    set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return & return
    set resultCount to 0
    $dateFilter
    set allAccounts to every account
    repeat with anAccount in allAccounts
        set accountName to name of anAccount
        $accountFilterStart
        try
            set accountMailboxes to every mailbox of anAccount
            repeat with aMailbox in accountMailboxes
                try
                    set mailboxName to name of aMailbox
                    if mailboxName is "INBOX" or mailboxName is "Inbox" then
                        set mailboxMessages to every message of aMailbox
                        repeat with aMessage in mailboxMessages
                            if resultCount >= $maxResults then exit repeat
                            try
                                set messageSender to sender of aMessage
                                set messageDate to date received of aMessage
                                set lowerSender to my lowercase(messageSender)
                                set isNewsletter to false
                                if $platformChecks then
                                    set isNewsletter to true
                                end if
                                if $keywordChecks then
                                    set isNewsletter to true
                                end if
                                if isNewsletter$dateCheck then
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
                                    $contentScript
                                    set outputText to outputText & return
                                    set resultCount to resultCount + 1
                                end if
                            end try
                        end repeat
                    end if
                end try
                if resultCount >= $maxResults then exit repeat
            end repeat
        end try
        $accountFilterEnd
        if resultCount >= $maxResults then exit repeat
    end repeat
    set outputText to outputText & "========================================" & return
    set outputText to outputText & "FOUND: " & resultCount & " newsletter(s)" & return
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
    return CallToolResult.fromContent(
      [TextContent(text: 'Error: sender parameter is required')],
    );
  }

  final account = args['account'] as String?;
  final timeRange = args['time_range'] as String? ?? 'week';
  final maxResults = args['max_results'] as int? ?? 15;
  final includeContent = args['include_content'] as bool? ?? true;
  final maxContentLength = args['max_content_length'] as int? ?? 400;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';

  final daysBack = timeRanges[timeRange.toLowerCase()] ?? 7;
  final isYesterday = timeRange.toLowerCase() == 'yesterday';

  final escapedSender = escapeAppleScript(sender);
  final escapedMailbox = escapeAppleScript(mailbox);
  final searchAllMailboxes = mailbox == 'All';

  final contentScript = includeContent
      ? '''
                                    try
                                        set msgContent to content of aMessage
                                        set AppleScript's text item delimiters to {return, linefeed}
                                        set contentParts to text items of msgContent
                                        set AppleScript's text item delimiters to " "
                                        set cleanText to contentParts as string
                                        set AppleScript's text item delimiters to ""
                                        if length of cleanText > $maxContentLength then
                                            set contentPreview to text 1 thru $maxContentLength of cleanText & "..."
                                        else
                                            set contentPreview to cleanText
                                        end if
                                        set outputText to outputText & "   Content: " & contentPreview & return
                                    on error
                                        set outputText to outputText & "   Content: [Not available]" & return
                                    end try
'''
      : '';

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
                                    $contentScript
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

/// Handles the get-email-thread operation.
///
/// Thread/conversation view with Re:/Fwd: prefix stripping.
Future<CallToolResult> handleGetEmailThread(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return CallToolResult.fromContent(
      [TextContent(text: 'Error: account parameter is required')],
    );
  }

  final subjectKeyword = args['subject_keyword'] as String?;
  if (subjectKeyword == null) {
    return CallToolResult.fromContent(
      [
        TextContent(text: 'Error: subject_keyword parameter is required')
      ],
    );
  }

  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final maxMessages = args['max_messages'] as int? ?? 50;

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // Strip thread prefixes for matching
  var cleanedKeyword = subjectKeyword;
  for (final prefix in threadPrefixes) {
    cleanedKeyword = cleanedKeyword.replaceAll(prefix, '').trim();
  }
  final escapedKeyword = escapeAppleScript(cleanedKeyword);

  final mailboxScript = '''
        try
            set searchMailbox to mailbox "$escapedMailbox" of targetAccount
        on error
            if "$escapedMailbox" is "INBOX" then
                set searchMailbox to mailbox "Inbox" of targetAccount
            else if "$escapedMailbox" is "All" then
                set searchMailboxes to every mailbox of targetAccount
                set useAllMailboxes to true
            else
                error "Mailbox not found: $escapedMailbox"
            end if
        end try

        if "$escapedMailbox" is not "All" then
            set searchMailboxes to {searchMailbox}
            set useAllMailboxes to false
        end if
''';

  final script = '''
tell application "Mail"
    set outputText to "EMAIL THREAD VIEW" & return & return
    set outputText to outputText & "Thread topic: $escapedKeyword" & return
    set outputText to outputText & "Account: $escapedAccount" & return & return
    set threadMessages to {}

    try
        set targetAccount to account "$escapedAccount"
        $mailboxScript

        repeat with currentMailbox in searchMailboxes
            set mailboxMessages to every message of currentMailbox

            repeat with aMessage in mailboxMessages
                if (count of threadMessages) >= $maxMessages then exit repeat

                try
                    set messageSubject to subject of aMessage

                    set cleanSubject to messageSubject
                    if cleanSubject starts with "Re: " then
                        set cleanSubject to text 5 thru -1 of cleanSubject
                    end if
                    if cleanSubject starts with "Fwd: " or cleanSubject starts with "FW: " then
                        set cleanSubject to text 6 thru -1 of cleanSubject
                    end if

                    if cleanSubject contains "$escapedKeyword" or messageSubject contains "$escapedKeyword" then
                        set end of threadMessages to aMessage
                    end if
                end try
            end repeat
        end repeat

        set messageCount to count of threadMessages
        set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return
        set outputText to outputText & "FOUND " & messageCount & " MESSAGE(S) IN THREAD" & return
        set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return & return

        repeat with aMessage in threadMessages
            try
                set messageSubject to subject of aMessage
                set messageSender to sender of aMessage
                set messageDate to date received of aMessage
                set messageRead to read status of aMessage

                if messageRead then
                    set readIndicator to "✓"
                else
                    set readIndicator to "✉"
                end if

                set outputText to outputText & readIndicator & " " & messageSubject & return
                set outputText to outputText & "   From: " & messageSender & return
                set outputText to outputText & "   Date: " & (messageDate as string) & return

                try
                    set msgContent to content of aMessage
                    set AppleScript's text item delimiters to {return, linefeed}
                    set contentParts to text items of msgContent
                    set AppleScript's text item delimiters to " "
                    set cleanText to contentParts as string
                    set AppleScript's text item delimiters to ""

                    if length of cleanText > 150 then
                        set contentPreview to text 1 thru 150 of cleanText & "..."
                    else
                        set contentPreview to cleanText
                    end if

                    set outputText to outputText & "   Preview: " & contentPreview & return
                end try

                set outputText to outputText & return
            end try
        end repeat

    on error errMsg
        return "Error: " & errMsg
    end try

    return outputText
end tell
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Handles the search-all-accounts operation.
///
/// Cross-account unified search with date-sorted results.
Future<CallToolResult> handleSearchAllAccounts(
    Map<String, dynamic> args) async {
  final subjectKeyword = args['subject_keyword'] as String?;
  final sender = args['sender'] as String?;
  final daysBack = args['days_back'] as int? ?? 7;
  final maxResults = args['max_results'] as int? ?? 30;
  final includeContent = args['include_content'] as bool? ?? true;
  final maxContentLength = args['max_content_length'] as int? ?? 400;

  // Build date filter
  final dateFilter = daysBack > 0
      ? '''
            set cutoffDate to (current date) - ($daysBack * days)
            if messageDate < cutoffDate then
                set skipMessage to true
            end if
'''
      : '';

  // Build subject filter
  final subjectFilter = subjectKeyword != null
      ? '''
            set lowerSubject to my lowercase(messageSubject)
            set lowerKeyword to my lowercase("${escapeAppleScript(subjectKeyword)}")
            if lowerSubject does not contain lowerKeyword then
                set skipMessage to true
            end if
'''
      : '';

  // Build sender filter
  final senderFilter = sender != null
      ? '''
            set lowerSender to my lowercase(messageSender)
            set lowerSenderFilter to my lowercase("${escapeAppleScript(sender)}")
            if lowerSender does not contain lowerSenderFilter then
                set skipMessage to true
            end if
'''
      : '';

  // Build content retrieval
  final contentRetrieval = includeContent
      ? '''
            try
                set messageContent to content of msg
                if length of messageContent > $maxContentLength then
                    set messageContent to text 1 thru $maxContentLength of messageContent & "..."
                end if
                set messageContent to my replaceText(messageContent, return, " ")
                set messageContent to my replaceText(messageContent, linefeed, " ")
            on error
                set messageContent to "(Content unavailable)"
            end try
            set emailRecord to emailRecord & "Content: " & messageContent & linefeed
'''
      : '';

  final script = '''
$lowercaseHandler

on replaceText(theText, searchStr, replaceStr)
    set AppleScript's text item delimiters to searchStr
    set theItems to text items of theText
    set AppleScript's text item delimiters to replaceStr
    set theText to theItems as text
    set AppleScript's text item delimiters to ""
    return theText
end replaceText

tell application "Mail"
    set allResults to {}
    set allAccounts to every account

    repeat with acct in allAccounts
        set acctName to name of acct

        set inboxMailbox to missing value
        try
            set inboxMailbox to mailbox "INBOX" of acct
        on error
            repeat with mb in mailboxes of acct
                set mbName to name of mb
                if mbName is "INBOX" or mbName is "Inbox" then
                    set inboxMailbox to mb
                    exit repeat
                end if
            end repeat
        end try

        if inboxMailbox is not missing value then
            try
                set msgs to messages of inboxMailbox

                repeat with msg in msgs
                    set skipMessage to false

                    try
                        set messageSubject to subject of msg
                        set messageSender to sender of msg
                        set messageDate to date received of msg
                        set messageRead to read status of msg
                    on error
                        set skipMessage to true
                    end try

                    if not skipMessage then
                        $dateFilter
                    end if

                    if not skipMessage then
                        $subjectFilter
                    end if

                    if not skipMessage then
                        $senderFilter
                    end if

                    if not skipMessage then
                        set emailRecord to ""
                        set emailRecord to emailRecord & "Account: " & acctName & linefeed
                        set emailRecord to emailRecord & "Subject: " & messageSubject & linefeed
                        set emailRecord to emailRecord & "From: " & messageSender & linefeed
                        set emailRecord to emailRecord & "Date: " & (messageDate as string) & linefeed
                        if messageRead then
                            set emailRecord to emailRecord & "Status: Read" & linefeed
                        else
                            set emailRecord to emailRecord & "Status: UNREAD" & linefeed
                        end if
                        $contentRetrieval

                        set end of allResults to {emailDate:messageDate, emailText:emailRecord}
                    end if

                    if (count of allResults) >= $maxResults then
                        exit repeat
                    end if
                end repeat
            on error errMsg
                -- Skip this account if there's an error
            end try
        end if

        if (count of allResults) >= $maxResults then
            exit repeat
        end if
    end repeat

    set sortedResults to my sortByDate(allResults)

    set outputText to ""
    set emailCount to count of sortedResults

    if emailCount is 0 then
        return "No emails found matching your criteria across all accounts."
    end if

    set outputText to "=== Cross-Account Search Results ===" & linefeed
    set outputText to outputText & "Found " & emailCount & " email(s)" & linefeed
    set outputText to outputText & "---" & linefeed & linefeed

    repeat with emailItem in sortedResults
        set outputText to outputText & emailText of emailItem & linefeed & "---" & linefeed
    end repeat

    return outputText
end tell

on sortByDate(theList)
    set listLength to count of theList
    repeat with i from 1 to listLength - 1
        repeat with j from 1 to listLength - i
            if emailDate of item j of theList < emailDate of item (j + 1) of theList then
                set temp to item j of theList
                set item j of theList to item (j + 1) of theList
                set item (j + 1) of theList to temp
            end if
        end repeat
    end repeat
    return theList
end sortByDate
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Returns the dispatch map for all search operations.
Map<String, Future<CallToolResult> Function(Map<String, dynamic>)>
    getSearchOperations() {
  return {
    'get-email-with-content': handleGetEmailWithContent,
    'search-emails': handleSearchEmails,
    'search-by-sender': handleSearchBySender,
    'search-email-content': handleSearchEmailContent,
    'get-newsletters': handleGetNewsletters,
    'get-recent-from-sender': handleGetRecentFromSender,
    'get-email-thread': handleGetEmailThread,
    'search-all-accounts': handleSearchAllAccounts,
  };
}
