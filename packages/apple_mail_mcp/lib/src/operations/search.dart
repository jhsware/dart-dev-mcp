// Search operations: finding and filtering emails.
//
// Ported from Python apple-mail-mcp/apple_mail_mcp/tools/search.py.
// All operations are read-only.
//
// Core search operations remain here; sender-related and advanced operations
// have been split into search_sender.dart and search_advanced.dart.

import 'package:mcp_dart/mcp_dart.dart';

import '../core.dart';
import '../constants.dart';
import 'search_sender.dart';
import 'search_advanced.dart';

/// Handles the search-emails operation.
///
/// Unified advanced search with multiple filter criteria. When a `query`
/// parameter is provided with multiple space-separated keywords, emails
/// matching ANY keyword are returned (OR logic).
Future<CallToolResult> handleSearchEmails(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return actionableError(
      'account parameter is required for search-emails.',
      'Use list-accounts to see available accounts.',
    );
  }

  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final query = args['query'] as String?;
  final subjectKeyword = args['subject_keyword'] as String?;
  final sender = args['sender'] as String?;
  final hasAttachments = args['has_attachments'] as bool?;
  final readStatus = args['read_status'] as String? ?? 'all';
  final includeContent = args['include_content'] as bool? ?? false;
  final maxResults = args['max_results'] as int? ?? 20;

  // Validate query if provided
  if (query != null && query.trim().isEmpty) {
    return actionableError(
      'Empty query provided.',
      'Provide one or more search keywords separated by spaces.',
    );
  }

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // Build OR-based query condition when query is provided
  String queryCondition = '';
  if (query != null) {
    final keywords =
        query.split(' ').where((k) => k.trim().isNotEmpty).toList();
    final orParts = <String>[];
    for (final keyword in keywords) {
      final escaped = escapeAppleScript(keyword.toLowerCase());
      orParts.add('lowerSubject contains "$escaped"');
      orParts.add('lowerSender contains "$escaped"');
    }
    queryCondition = orParts.join(' or ');
  }

  // Build AND conditions from other filters
  final andConditions = <String>[];
  if (subjectKeyword != null) {
    andConditions
        .add('lowerSubject contains "${escapeAppleScript(subjectKeyword.toLowerCase())}"');
  }
  if (sender != null) {
    andConditions.add('lowerSender contains "${escapeAppleScript(sender.toLowerCase())}"');
  }
  if (hasAttachments != null) {
    if (hasAttachments) {
      andConditions.add('(count of mail attachments of aMessage) > 0');
    } else {
      andConditions.add('(count of mail attachments of aMessage) = 0');
    }
  }
  if (readStatus == 'read') {
    andConditions.add('messageRead is true');
  } else if (readStatus == 'unread') {
    andConditions.add('messageRead is false');
  }

  // Combine: (OR query) AND (other filters)
  String conditionStr;
  if (queryCondition.isNotEmpty && andConditions.isNotEmpty) {
    conditionStr = '($queryCondition) and ${andConditions.join(' and ')}';
  } else if (queryCondition.isNotEmpty) {
    conditionStr = queryCondition;
  } else if (andConditions.isNotEmpty) {
    conditionStr = andConditions.join(' and ');
  } else {
    conditionStr = 'true';
  }

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
                    return "ERROR:Mailbox \\"$escapedMailbox\\" not found. Use list-mailboxes to see available mailboxes."
                end if
            end try
            set searchMailboxes to {searchMailbox}
''';
  }

  final script = '''
$lowercaseHandler

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
                            set lowerSubject to my lowercase(messageSubject)
                            set lowerSender to my lowercase(messageSender)

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
        return "ERROR:" & errMsg
    end try

    return outputText
end tell
''';

  try {
    final result = await runAppleScript(script);
    if (result.startsWith('ERROR:')) {
      final errorMsg = result.substring(6);
      return actionableError(errorMsg, '');
    }
    return CallToolResult.fromContent([TextContent(text: result)]);
  } catch (e) {
    return actionableError(
      'Failed to search emails: $e',
      'Check that Apple Mail is running and the account exists.',
    );
  }
}

/// Handles the search-email-content operation.
///
/// Full-text body content search (slower). When multiple keywords are
/// provided (space-separated), emails matching ANY keyword are returned
/// (OR logic).
Future<CallToolResult> handleSearchEmailContent(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return actionableError(
      'account parameter is required for search-email-content.',
      'Use list-accounts to see available accounts.',
    );
  }

  final query = args['query'] as String?;
  if (query == null || query.trim().isEmpty) {
    return actionableError(
      'query parameter is required for search-email-content.',
      'Provide one or more search keywords separated by spaces.',
    );
  }

  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final searchBody = args['search_body'] as bool? ?? true;
  final maxResults = args['max_results'] as int? ?? 10;
  final maxContentLength = args['max_content_length'] as int? ?? 600;

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // Build OR-based search conditions for multiple keywords
  final keywords =
      query.split(' ').where((k) => k.trim().isNotEmpty).toList();
  final searchParts = <String>[];
  for (final keyword in keywords) {
    final escaped = escapeAppleScript(keyword.toLowerCase());
    searchParts.add('lowerSubject contains "$escaped"');
    if (searchBody) {
      searchParts.add('lowerContent contains "$escaped"');
    }
  }
  final searchCondition = searchParts.join(' or ');

  final escapedSearch = escapeAppleScript(query.toLowerCase());

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
                return "ERROR:Mailbox \\"$escapedMailbox\\" not found. Use list-mailboxes to see available mailboxes."
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
        return "ERROR:" & errMsg
    end try
    return outputText
end tell
''';

  try {
    final result = await runAppleScript(script);
    if (result.startsWith('ERROR:')) {
      final errorMsg = result.substring(6);
      return actionableError(errorMsg, '');
    }
    return CallToolResult.fromContent([TextContent(text: result)]);
  } catch (e) {
    return actionableError(
      'Failed to search email content: $e',
      'Check that Apple Mail is running and the account exists.',
    );
  }
}

/// Returns the dispatch map for all search operations.
///
/// Merges core, sender, and advanced search operations into a single map.
Map<String, Future<CallToolResult> Function(Map<String, dynamic>)>
    getSearchOperations() {
  return {
    'search-emails': handleSearchEmails,
    'search-email-content': handleSearchEmailContent,
    ...getSenderSearchOperations(),
    ...getAdvancedSearchOperations(),
  };
}
