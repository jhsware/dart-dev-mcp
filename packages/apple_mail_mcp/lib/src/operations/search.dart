// Search operations: finding and filtering emails.
//
// Ported from Python apple-mail-mcp/apple_mail_mcp/tools/search.py.
// All operations are read-only.
//
// Core search operations remain here; sender-related and advanced operations
// have been split into search_sender.dart and search_advanced.dart.

import 'package:mcp_dart/mcp_dart.dart';

import '../core.dart';
import 'search_sender.dart';
import 'search_advanced.dart';

/// Builds AppleScript date setup and condition fragments for date filtering.
///
/// Returns a record with `setup` (AppleScript lines before the loop) and
/// `check` (condition fragment to use inside the loop).
({String setup, String check}) _buildDateFilter({
  required int daysBack,
  String? startDate,
  String? endDate,
}) {
  final setupParts = <String>[];
  final checkParts = <String>[];

  if (daysBack > 0) {
    setupParts.add('set cutoffDate to (current date) - ($daysBack * days)');
    checkParts.add('messageDate > cutoffDate');
  }

  if (startDate != null) {
    // Parse YYYY-MM-DD and build AppleScript date
    final parts = startDate.split('-');
    final year = parts[0];
    final month = parts[1];
    final day = parts[2];
    setupParts.add('''
            set startDateObj to current date
            set year of startDateObj to $year
            set month of startDateObj to $month
            set day of startDateObj to $day
            set hours of startDateObj to 0
            set minutes of startDateObj to 0
            set seconds of startDateObj to 0''');
    checkParts.add('messageDate >= startDateObj');
  }

  if (endDate != null) {
    final parts = endDate.split('-');
    final year = parts[0];
    final month = parts[1];
    final day = parts[2];
    setupParts.add('''
            set endDateObj to current date
            set year of endDateObj to $year
            set month of endDateObj to $month
            set day of endDateObj to $day
            set hours of endDateObj to 23
            set minutes of endDateObj to 59
            set seconds of endDateObj to 59''');
    checkParts.add('messageDate <= endDateObj');
  }

  return (
    setup: setupParts.join('\n'),
    check: checkParts.isEmpty ? '' : checkParts.join(' and '),
  );
}

/// Validates a date string is in YYYY-MM-DD format.
/// Returns an error [CallToolResult] if invalid, or null if valid.
CallToolResult? _validateDateParam(String? value, String paramName) {
  if (value == null) return null;
  final dateRegex = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  if (!dateRegex.hasMatch(value)) {
    return actionableError(
      'Invalid $paramName "$value".',
      'Use ISO format: YYYY-MM-DD',
    );
  }
  return null;
}

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
  final offset = args['offset'] as int? ?? 0;
  final daysBack = args['days_back'] as int? ?? 0;
  final startDate = args['start_date'] as String?;
  final endDate = args['end_date'] as String?;

  // Validate query if provided
  if (query != null && query.trim().isEmpty) {
    return actionableError(
      'Empty query provided.',
      'Provide one or more search keywords separated by spaces.',
    );
  }

  // Validate date parameters
  final startDateErr = _validateDateParam(startDate, 'start_date');
  if (startDateErr != null) return startDateErr;
  final endDateErr = _validateDateParam(endDate, 'end_date');
  if (endDateErr != null) return endDateErr;

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // Build date filter
  final dateFilter = _buildDateFilter(
    daysBack: daysBack,
    startDate: startDate,
    endDate: endDate,
  );

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

  // Build date check condition for inside the loop
  final dateCheckScript = dateFilter.check.isNotEmpty
      ? '''
                            -- date filtering
                            if not (${dateFilter.check}) then
                                set skipMessage to true
                            end if'''
      : '';

  final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to "SEARCH RESULTS" & return & return
    set outputText to outputText & "Searching in: $escapedMailbox" & return
    set outputText to outputText & "Account: $escapedAccount" & return & return
    set matchedCount to 0
    set resultCount to 0

    ${dateFilter.setup}

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
                            set skipMessage to false
                            set messageSubject to subject of aMessage
                            set messageSender to sender of aMessage
                            set messageDate to date received of aMessage
                            set messageRead to read status of aMessage
                            set lowerSubject to my lowercase(messageSubject)
                            set lowerSender to my lowercase(messageSender)

                            $dateCheckScript

                            if not skipMessage and ($conditionStr) then
                                set matchedCount to matchedCount + 1
                                if matchedCount > $offset then
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
                            end if
                        end try
                    end repeat
                end if
            on error
                -- Skip mailboxes that throw errors
            end try
        end repeat

        set outputText to outputText & "========================================" & return
        set outputText to outputText & "FOUND: " & matchedCount & " matching email(s), showing " & resultCount & " (offset: $offset)" & return
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
  final offset = args['offset'] as int? ?? 0;
  final daysBack = args['days_back'] as int? ?? 0;
  final startDate = args['start_date'] as String?;
  final endDate = args['end_date'] as String?;

  // Validate date parameters
  final startDateErr = _validateDateParam(startDate, 'start_date');
  if (startDateErr != null) return startDateErr;
  final endDateErr = _validateDateParam(endDate, 'end_date');
  if (endDateErr != null) return endDateErr;

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // Build date filter
  final dateFilter = _buildDateFilter(
    daysBack: daysBack,
    startDate: startDate,
    endDate: endDate,
  );

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

  // Build date check condition for inside the loop
  final dateCheckScript = dateFilter.check.isNotEmpty
      ? '''
                -- date filtering
                if not (${dateFilter.check}) then
                    set skipMessage to true
                end if'''
      : '';

  final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to "🔎 CONTENT SEARCH: $escapedSearch" & return
    set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return
    set outputText to outputText & "⚠ Note: Body search is slower - searching $maxResults results max" & return & return
    set matchedCount to 0
    set resultCount to 0

    ${dateFilter.setup}

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
                set skipMessage to false
                set messageDate to date received of aMessage

                $dateCheckScript

                if not skipMessage then
                    set messageSubject to subject of aMessage
                    set msgContent to ""
                    try
                        set msgContent to content of aMessage
                    end try
                    set lowerSubject to my lowercase(messageSubject)
                    set lowerContent to my lowercase(msgContent)
                    if $searchCondition then
                        set matchedCount to matchedCount + 1
                        if matchedCount > $offset then
                            set messageSender to sender of aMessage
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
                    end if
                end if
            end try
        end repeat
        set outputText to outputText & "========================================" & return
        set outputText to outputText & "FOUND: " & matchedCount & " email(s) matching \\"$escapedSearch\\", showing " & resultCount & " (offset: $offset)" & return
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
