// Advanced search operations: newsletters, threads, cross-account.
//
// Split from search.dart for maintainability.

import 'package:mcp_dart/mcp_dart.dart';

import '../core.dart';
import '../constants.dart';

/// Handles the get-newsletters operation.
///
/// Detects newsletters using sender pattern matching.
Future<CallToolResult> handleGetNewsletters(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  final daysBack = args['days_back'] as int? ?? 7;
  final maxResults = args['max_results'] as int? ?? 25;

  final escapedAccount =
      account != null ? escapeAppleScript(account) : null;

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
                                    set outputText to outputText & "   ID: " & (message id of aMessage) & return
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

/// Handles the get-email-thread operation.
///
/// Thread/conversation view with Re:/Fwd: prefix stripping.
Future<CallToolResult> handleGetEmailThread(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return actionableError(
      'account parameter is required for get-email-thread.',
      'Use list-accounts to see available accounts.',
    );
  }

  final subjectKeyword = args['subject_keyword'] as String?;
  if (subjectKeyword == null) {
    return actionableError(
      'subject_keyword parameter is required for get-email-thread.',
      'Provide a keyword to search for in email subject lines.',
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
                set outputText to outputText & "   ID: " & (message id of aMessage) & return
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
                        set emailRecord to emailRecord & "ID: " & (message id of msg) & linefeed
                        if messageRead then
                            set emailRecord to emailRecord & "Status: Read" & linefeed
                        else
                            set emailRecord to emailRecord & "Status: UNREAD" & linefeed
                        end if

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

/// Returns the dispatch map for advanced search operations.
Map<String, Future<CallToolResult> Function(Map<String, dynamic>)>
    getAdvancedSearchOperations() {
  return {
    'get-newsletters': handleGetNewsletters,
    'get-email-thread': handleGetEmailThread,
    'search-all-accounts': handleSearchAllAccounts,
  };
}
