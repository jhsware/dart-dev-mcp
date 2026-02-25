// Inbox operations: listing, counting, and overview.
//
// Ported from Python apple-mail-mcp/apple_mail_mcp/tools/inbox.py.
// All operations are read-only.

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../constants.dart';
import '../core.dart';

/// Handles the list-emails operation.
///
/// Batch-fetches emails with pagination (limit/offset), optional date
/// filtering, configurable field selection, and structured JSON output.
Future<CallToolResult> handleListEmails(Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final limit = args['limit'] as int? ?? 20;
  final offset = args['offset'] as int? ?? 0;
  final startDate = args['start_date'] as String?;
  final endDate = args['end_date'] as String?;
  final fieldsStr = args['fields'] as String?;


  // Validate and parse fields
  final requestedFields = fieldsStr != null
      ? fieldsStr.split(',').map((f) => f.trim()).toList()
      : defaultEmailFields;

  for (final field in requestedFields) {
    if (!allEmailFields.contains(field)) {
      return actionableError(
        'Unknown field "$field".',
        'Valid fields: ${allEmailFields.join(", ")}',
      );
    }
  }

  // Validate start_date format if provided
  if (startDate != null) {
    final dateRegex = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (!dateRegex.hasMatch(startDate)) {
      return actionableError(
        'Invalid start_date "$startDate".',
        'Use ISO format: YYYY-MM-DD',
      );
    }
  }

  // Validate end_date format if provided
  if (endDate != null) {
    final dateRegex = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (!dateRegex.hasMatch(endDate)) {
      return actionableError(
        'Invalid end_date "$endDate".',
        'Use ISO format: YYYY-MM-DD',
      );
    }
  }


  final escapedMailbox = escapeAppleScript(mailbox);

  // Build field extraction AppleScript snippets
  final fieldExtractions = <String>[];
  for (final field in requestedFields) {
    switch (field) {
      case 'sender':
        fieldExtractions.add(
            'set emailRecord to emailRecord & "From: " & sender of aMessage & linefeed');
      case 'subject':
        fieldExtractions.add(
            'set emailRecord to emailRecord & "Subject: " & subject of aMessage & linefeed');
      case 'date':
        fieldExtractions.add(
            'set emailRecord to emailRecord & "Date: " & (date received of aMessage as string) & linefeed');
      case 'message_id':
        fieldExtractions.add(
            'set emailRecord to emailRecord & "ID: " & message id of aMessage & linefeed');
      case 'read_status':
        fieldExtractions.add('''
                        if read status of aMessage then
                            set emailRecord to emailRecord & "ReadStatus: read" & linefeed
                        else
                            set emailRecord to emailRecord & "ReadStatus: unread" & linefeed
                        end if''');
      case 'mailbox':
        fieldExtractions
            .add('set emailRecord to emailRecord & "Mailbox: " & mailboxName & linefeed');
      case 'account':
        fieldExtractions.add(
            'set emailRecord to emailRecord & "Account: " & accountName & linefeed');
      case 'attachments':
        fieldExtractions.add('''
                        try
                            set attachCount to count of mail attachments of aMessage
                            if attachCount > 0 then
                                set attachNames to {}
                                repeat with anAttach in mail attachments of aMessage
                                    set end of attachNames to name of anAttach
                                end repeat
                                set AppleScript's text item delimiters to ", "
                                set attachStr to attachNames as string
                                set AppleScript's text item delimiters to ""
                                set emailRecord to emailRecord & "Attachments: " & attachCount & " (" & attachStr & ")" & linefeed
                            else
                                set emailRecord to emailRecord & "Attachments: 0" & linefeed
                            end if
                        on error
                            set emailRecord to emailRecord & "Attachments: [Error]" & linefeed
                        end try''');
    }
  }

  final fieldExtractionsScript = fieldExtractions.join('\n');

  // Build date filter
  String dateFilterSetup = '';
  String dateCheck = '';
  if (startDate != null) {
    dateFilterSetup += safeDateScript(
      varName: 'startFilterDate',
      dateStr: startDate,
    );

    dateCheck += '''
                        set msgDate to date received of aMessage
                        if msgDate < startFilterDate then
                            set skipMsg to true
                        end if''';
  }
  if (endDate != null) {
    dateFilterSetup += safeDateScript(
      varName: 'endFilterDate',
      dateStr: endDate,
      timeSeconds: 86399, // end of day
    );

    dateCheck += '''
                        ${startDate == null ? 'set msgDate to date received of aMessage' : ''}
                        if msgDate > endFilterDate then
                            set skipMsg to true
                        end if''';
  }


  // Build account loop
  String accountLoopStart;
  String accountLoopEnd;
  if (account != null) {
    final escapedAccount = escapeAppleScript(account);
    accountLoopStart = '''
        try
            set anAccount to account "$escapedAccount"
        on error
            return "ERROR:Account \\"$escapedAccount\\" not found. Use list-accounts to see available accounts."
        end try
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
            if collectedCount >= totalLimit then exit repeat
        end repeat
''';
  }

  // Build mailbox resolution
  String mailboxResolution;
  if (mailbox == 'INBOX') {
    mailboxResolution = '''
            try
                set targetMailbox to mailbox "INBOX" of anAccount
            on error
                try
                    set targetMailbox to mailbox "Inbox" of anAccount
                on error
                    set outputText to outputText & "ERROR_MAILBOX:Could not find INBOX for account " & accountName & linefeed
                    set skipAccount to true
                end try
            end try''';
  } else {
    mailboxResolution = '''
            try
                set targetMailbox to mailbox "$escapedMailbox" of anAccount
            on error
                set outputText to outputText & "ERROR_MAILBOX:Mailbox \\"$escapedMailbox\\" not found in account " & accountName & ". Use list-mailboxes to see available mailboxes." & linefeed
                set skipAccount to true
            end try''';
  }

  final totalLimit = offset + limit;

  final script = '''
tell application "Mail"
    set outputText to ""
    set collectedCount to 0
    set skippedCount to 0
    set totalAvailable to 0
    set totalLimit to $totalLimit

    $dateFilterSetup

    $accountLoopStart

            set skipAccount to false
            $mailboxResolution

            if not skipAccount then
                set mailboxName to name of targetMailbox
                set mailboxMsgCount to count of messages of targetMailbox
                set totalAvailable to totalAvailable + mailboxMsgCount
                set mailboxMessages to every message of targetMailbox

                repeat with aMessage in mailboxMessages
                    if collectedCount >= totalLimit then exit repeat

                    try
                        set skipMsg to false
                        $dateCheck

                        if not skipMsg then
                            set skippedCount to skippedCount + 1
                            if skippedCount > $offset then
                                set emailRecord to "✉ " & subject of aMessage & linefeed
                                $fieldExtractionsScript
                                set emailRecord to emailRecord & "---END---" & linefeed
                                set outputText to outputText & emailRecord
                                set collectedCount to collectedCount + 1
                            end if
                        end if
                    end try
                end repeat
            end if

    $accountLoopEnd

    set outputText to outputText & "TOTAL_AVAILABLE:" & totalAvailable & linefeed
    return outputText
end tell
''';

  try {
    final result = await runAppleScript(script);

    // Check for account-level errors
    if (result.startsWith('ERROR:')) {
      final errorMsg = result.substring(6);
      return actionableError(errorMsg, '');
    }

    // Parse AppleScript output into email maps
    final emails = <Map<String, String>>[];
    var totalAvailable = 0;

    // Extract total available from last line
    final lines = result.split('\n');
    for (final line in lines) {
      if (line.startsWith('TOTAL_AVAILABLE:')) {
        totalAvailable = int.tryParse(line.substring(16).trim()) ?? 0;
      }
    }

    // Parse email blocks
    Map<String, String>? current;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('TOTAL_AVAILABLE:')) continue;
      if (trimmed.startsWith('ERROR_MAILBOX:')) continue;

      if (trimmed == '---END---') {
        if (current != null) {
          emails.add(current);
          current = null;
        }
        continue;
      }

      if (trimmed.startsWith('✉') || trimmed.startsWith('✓')) {
        current = {
          'subject': trimmed.length >= 2 ? trimmed.substring(2).trim() : '',
        };

      } else if (current != null) {
        if (trimmed.startsWith('From: ')) {
          current['sender'] = trimmed.substring(6).trim();
        } else if (trimmed.startsWith('Subject: ')) {
          current['subject'] = trimmed.substring(9).trim();
        } else if (trimmed.startsWith('Date: ')) {
          current['date'] = trimmed.substring(6).trim();
        } else if (trimmed.startsWith('ID: ')) {
          current['message_id'] = trimmed.substring(4).trim();
        } else if (trimmed.startsWith('ReadStatus: ')) {
          current['read_status'] = trimmed.substring(12).trim();
        } else if (trimmed.startsWith('Mailbox: ')) {
          current['mailbox'] = trimmed.substring(9).trim();
        } else if (trimmed.startsWith('Account: ')) {
          current['account'] = trimmed.substring(9).trim();
        } else if (trimmed.startsWith('Attachments: ')) {
          current['attachments'] = trimmed.substring(13).trim();
        }
      }
    }

    final jsonOutput = buildJsonEmailOutput(
      emails: emails,
      offset: offset,
      limit: limit,
      totalAvailable: totalAvailable,
    );
    return CallToolResult.fromContent([TextContent(text: jsonOutput)]);
  } catch (e) {
    return actionableError(
      'Failed to list emails: $e',
      'Check that Apple Mail is running and the account/mailbox exists.',
    );
  }
}


/// Handles the get-email-by-id operation.
///
/// Fetches a specific email by its Apple Mail message ID, searching across
/// all accounts and mailboxes (or a specific account). Returns full details.
Future<CallToolResult> handleGetEmailById(Map<String, dynamic> args) async {
  final messageId = args['message_id'] as String?;
  if (messageId == null || messageId.isEmpty) {
    return actionableError(
      'message_id parameter is required for get-email-by-id.',
      'Provide the message ID from a previous list-emails or search operation.',
    );
  }

  final account = args['account'] as String?;
  final maxContentLength = args['max_content_length'] as int? ?? 5000;

  final escapedMessageId = escapeAppleScript(messageId);

  // Build account loop
  String accountLoopStart;
  String accountLoopEnd;
  if (account != null) {
    final escapedAccount = escapeAppleScript(account);
    accountLoopStart = '''
        try
            set anAccount to account "$escapedAccount"
        on error
            return "ERROR:Account \\"$escapedAccount\\" not found. Use list-accounts to see available accounts."
        end try
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
            if foundMessage then exit repeat
            set accountName to name of anAccount
''';
    accountLoopEnd = '''
        end repeat
''';
  }

  final script = '''
tell application "Mail"
    set foundMessage to false
    set outputText to ""

    $accountLoopStart

            set accountMailboxes to every mailbox of anAccount
            repeat with aMailbox in accountMailboxes
                if foundMessage then exit repeat

                try
                    set mailboxName to name of aMailbox
                    set mailboxMessages to every message of aMailbox

                    repeat with aMessage in mailboxMessages
                        if foundMessage then exit repeat

                        try
                            set msgId to message id of aMessage
                            if msgId is "$escapedMessageId" then
                                set foundMessage to true
                                set outputText to "FOUND" & linefeed
                                set outputText to outputText & "ID: " & msgId & linefeed
                                set outputText to outputText & "Subject: " & subject of aMessage & linefeed
                                set outputText to outputText & "From: " & sender of aMessage & linefeed
                                set outputText to outputText & "Date: " & (date received of aMessage as string) & linefeed

                                if read status of aMessage then
                                    set outputText to outputText & "ReadStatus: read" & linefeed
                                else
                                    set outputText to outputText & "ReadStatus: unread" & linefeed
                                end if

                                set outputText to outputText & "Account: " & accountName & linefeed
                                set outputText to outputText & "Mailbox: " & mailboxName & linefeed

                                try
                                    set msgContent to content of aMessage
                                    set AppleScript's text item delimiters to {return, linefeed}
                                    set contentParts to text items of msgContent
                                    set AppleScript's text item delimiters to " "
                                    set cleanText to contentParts as string
                                    set AppleScript's text item delimiters to ""
                                    if $maxContentLength > 0 and length of cleanText > $maxContentLength then
                                        set cleanText to text 1 thru $maxContentLength of cleanText & "..."
                                    end if
                                    set outputText to outputText & "Content: " & cleanText & linefeed
                                on error
                                    set outputText to outputText & "Content: [Not available]" & linefeed
                                end try

                                try
                                    set attachCount to count of mail attachments of aMessage
                                    if attachCount > 0 then
                                        set attachNames to {}
                                        repeat with anAttach in mail attachments of aMessage
                                            set end of attachNames to name of anAttach
                                        end repeat
                                        set AppleScript's text item delimiters to ", "
                                        set attachStr to attachNames as string
                                        set AppleScript's text item delimiters to ""
                                        set outputText to outputText & "Attachments: " & attachCount & " (" & attachStr & ")" & linefeed
                                    else
                                        set outputText to outputText & "Attachments: 0" & linefeed
                                    end if
                                on error
                                    set outputText to outputText & "Attachments: [Error]" & linefeed
                                end try
                            end if
                        end try
                    end repeat
                end try
            end repeat

    $accountLoopEnd

    if not foundMessage then
        return "NOT_FOUND"
    end if

    return outputText
end tell
''';

  try {
    final result = await runAppleScript(script);

    // Check for account error
    if (result.startsWith('ERROR:')) {
      final errorMsg = result.substring(6);
      return actionableError(errorMsg, '');
    }

    // Check for not found
    if (result == 'NOT_FOUND') {
      return actionableError(
        'No email found with message ID "$messageId".',
        'The message may have been moved or deleted. Use list-emails or search-emails to find current emails.',
      );
    }

    // Parse the output into a JSON object
    final email = <String, String>{};
    for (final line in result.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed == 'FOUND') continue;

      if (trimmed.startsWith('ID: ')) {
        email['message_id'] = trimmed.substring(4).trim();
      } else if (trimmed.startsWith('Subject: ')) {
        email['subject'] = trimmed.substring(9).trim();
      } else if (trimmed.startsWith('From: ')) {
        email['sender'] = trimmed.substring(6).trim();
      } else if (trimmed.startsWith('Date: ')) {
        email['date'] = trimmed.substring(6).trim();
      } else if (trimmed.startsWith('ReadStatus: ')) {
        email['read_status'] = trimmed.substring(12).trim();
      } else if (trimmed.startsWith('Account: ')) {
        email['account'] = trimmed.substring(9).trim();
      } else if (trimmed.startsWith('Mailbox: ')) {
        email['mailbox'] = trimmed.substring(9).trim();
      } else if (trimmed.startsWith('Content: ')) {
        email['content'] = trimmed.substring(9).trim();
      } else if (trimmed.startsWith('Attachments: ')) {
        email['attachments'] = trimmed.substring(13).trim();
      }
    }

    final jsonOutput = const JsonEncoder.withIndent('  ').convert(email);
    return CallToolResult.fromContent([TextContent(text: jsonOutput)]);
  } catch (e) {
    return actionableError(
      'Failed to fetch email by ID: $e',
      'Check that Apple Mail is running.',
    );
  }
}


/// Handles the list-inbox-emails operation.
///
/// Lists all inbox emails across all accounts or a specific one.
Future<CallToolResult> handleListInboxEmails(
    Map<String, dynamic> args) async {
  final maxEmails = args['max_emails'] as int? ?? 0;
  final includeRead = args['include_read'] as bool? ?? true;
  final startDate = args['start_date'] as String?;
  final endDate = args['end_date'] as String?;

  // Validate date formats
  final dateRegex = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  if (startDate != null && !dateRegex.hasMatch(startDate)) {
    return actionableError(
      'Invalid start_date "$startDate".',
      'Use ISO format: YYYY-MM-DD',
    );
  }
  if (endDate != null && !dateRegex.hasMatch(endDate)) {
    return actionableError(
      'Invalid end_date "$endDate".',
      'Use ISO format: YYYY-MM-DD',
    );
  }

  // Build date filter
  String dateFilterSetup = '';
  String dateCheck = '';
  if (startDate != null) {
    dateFilterSetup += safeDateScript(
      varName: 'startFilterDate',
      dateStr: startDate,
    );
    dateCheck += '''
                        if messageDate < startFilterDate then
                            set shouldInclude to false
                        end if''';
  }
  if (endDate != null) {
    dateFilterSetup += safeDateScript(
      varName: 'endFilterDate',
      dateStr: endDate,
      timeSeconds: 86399,
    );
    dateCheck += '''
                        if messageDate > endFilterDate then
                            set shouldInclude to false
                        end if''';
  }

  final script = '''

tell application "Mail"
    set outputText to "INBOX EMAILS - ALL ACCOUNTS" & return & return
    set totalCount to 0
    set allAccounts to every account

    $dateFilterSetup

    repeat with anAccount in allAccounts
        set accountName to name of anAccount

        try
            ${inboxMailboxScript(varName: 'inboxMailbox', accountVar: 'anAccount')}
            set inboxMessages to every message of inboxMailbox
            set messageCount to count of inboxMessages

            if messageCount > 0 then
                set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return
                set outputText to outputText & "📧 ACCOUNT: " & accountName & " (" & messageCount & " messages)" & return
                set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return & return

                set currentIndex to 0
                repeat with aMessage in inboxMessages
                    set currentIndex to currentIndex + 1
                    if $maxEmails > 0 and currentIndex > $maxEmails then exit repeat

                    try
                        set messageSubject to subject of aMessage
                        set messageSender to sender of aMessage
                        set messageDate to date received of aMessage
                        set messageRead to read status of aMessage

                        set shouldInclude to true
                        if not ${includeRead.toString()} and messageRead then
                            set shouldInclude to false
                        end if
                        $dateCheck

                        if shouldInclude then
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


                            set totalCount to totalCount + 1
                        end if
                    end try
                end repeat
            end if
        on error errMsg
            set outputText to outputText & "⚠ Error accessing inbox for account " & accountName & return
            set outputText to outputText & "   " & errMsg & return & return
        end try
    end repeat

    set outputText to outputText & "========================================" & return
    set outputText to outputText & "TOTAL EMAILS: " & totalCount & return
    set outputText to outputText & "========================================" & return

    return outputText
end tell
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Handles the get-unread-count operation.
///
/// Returns unread count per account as structured text.
Future<CallToolResult> handleGetUnreadCount(
    Map<String, dynamic> args) async {
  final script = '''
tell application "Mail"
    set resultList to {}
    set allAccounts to every account

    repeat with anAccount in allAccounts
        set accountName to name of anAccount

        try
            ${inboxMailboxScript(varName: 'inboxMailbox', accountVar: 'anAccount')}
            set unreadCount to unread count of inboxMailbox
            set end of resultList to accountName & ":" & unreadCount
        on error
            set end of resultList to accountName & ":ERROR"
        end try
    end repeat

    set AppleScript's text item delimiters to "|"
    return resultList as string
end tell
''';

  final result = await runAppleScript(script);

  // Parse the result into a readable format
  final buffer = StringBuffer('Unread Email Counts:\n');
  for (final item in result.split('|')) {
    if (item.contains(':')) {
      final parts = item.split(':');
      final accountName = parts[0];
      final count = parts.length > 1 ? parts[1] : '?';
      if (count == 'ERROR') {
        buffer.writeln('  $accountName: Error accessing inbox');
      } else {
        buffer.writeln('  $accountName: $count unread');
      }
    }
  }

  return CallToolResult.fromContent(
      [TextContent(text: buffer.toString())]);
}

/// Handles the list-accounts operation.
///
/// Returns a list of all Mail account names.
Future<CallToolResult> handleListAccounts(
    Map<String, dynamic> args) async {
  final script = '''
tell application "Mail"
    set accountNames to {}
    set allAccounts to every account

    repeat with anAccount in allAccounts
        set accountName to name of anAccount
        set end of accountNames to accountName
    end repeat

    set AppleScript's text item delimiters to "|"
    return accountNames as string
end tell
''';

  final result = await runAppleScript(script);
  final accounts = result.isNotEmpty ? result.split('|') : <String>[];

  final buffer = StringBuffer('Mail Accounts:\n');
  for (final account in accounts) {
    buffer.writeln('  - $account');
  }

  return CallToolResult.fromContent(
      [TextContent(text: buffer.toString())]);
}

/// Handles the get-recent-emails operation.
///
/// Gets N most recent emails from a specific account.
Future<CallToolResult> handleGetRecentEmails(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return actionableError(
      'account parameter is required for get-recent-emails.',
      'Use list-accounts to see available accounts.',
    );
  }

  final count = args['count'] as int? ?? 10;
  final escapedAccount = escapeAppleScript(account);

  final script = '''
tell application "Mail"
    set outputText to "RECENT EMAILS - $escapedAccount" & return & return

    try
        set targetAccount to account "$escapedAccount"
        ${inboxMailboxScript(varName: 'inboxMailbox', accountVar: 'targetAccount')}
        set inboxMessages to every message of inboxMailbox

        set currentIndex to 0
        repeat with aMessage in inboxMessages
            set currentIndex to currentIndex + 1
            if currentIndex > $count then exit repeat

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



            end try
        end repeat

        set outputText to outputText & "========================================" & return
        set outputText to outputText & "Showing " & (currentIndex - 1) & " email(s)" & return
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

/// Handles the list-mailboxes operation.
///
/// Lists all mailboxes/folders with optional message counts.
Future<CallToolResult> handleListMailboxes(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  final includeCounts = args['include_counts'] as bool? ?? true;

  final countScript = includeCounts
      ? '''
        try
            set msgCount to count of messages of aMailbox
            set unreadCount to unread count of aMailbox
            set outputText to outputText & " (" & msgCount & " total, " & unreadCount & " unread)"
        on error
            set outputText to outputText & " (count unavailable)"
        end try
'''
      : '';

  final subCountScript = includeCounts
      ? '''
        try
            set msgCount to count of messages of subBox
            set unreadCount to unread count of subBox
            set outputText to outputText & " (" & msgCount & " total, " & unreadCount & " unread)"
        on error
            set outputText to outputText & " (count unavailable)"
        end try
'''
      : '';

  final accountFilterStart = account != null
      ? 'if accountName is "${escapeAppleScript(account)}" then'
      : '';
  final accountFilterEnd = account != null ? 'end if' : '';

  final script = '''
tell application "Mail"
    set outputText to "MAILBOXES" & return & return
    set allAccounts to every account

    repeat with anAccount in allAccounts
        set accountName to name of anAccount

        $accountFilterStart
            set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return
            set outputText to outputText & "📁 ACCOUNT: " & accountName & return
            set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return & return

            try
                set accountMailboxes to every mailbox of anAccount

                repeat with aMailbox in accountMailboxes
                    set mailboxName to name of aMailbox
                    set outputText to outputText & "  📂 " & mailboxName

                    $countScript

                    set outputText to outputText & return

                    -- List sub-mailboxes with path notation
                    try
                        set subMailboxes to every mailbox of aMailbox
                        repeat with subBox in subMailboxes
                            set subName to name of subBox
                            set outputText to outputText & "    └─ " & subName & " [Path: " & mailboxName & "/" & subName & "]"

                            $subCountScript

                            set outputText to outputText & return
                        end repeat
                    end try
                end repeat

                set outputText to outputText & return
            on error errMsg
                set outputText to outputText & "  ⚠ Error accessing mailboxes: " & errMsg & return & return
            end try
        $accountFilterEnd
    end repeat

    return outputText
end tell
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Handles the get-inbox-overview operation.
///
/// Comprehensive dashboard: unread counts, mailbox structure, recent emails,
/// and action suggestions.
Future<CallToolResult> handleGetInboxOverview(
    Map<String, dynamic> args) async {
  final script = '''
tell application "Mail"
    set outputText to "╔══════════════════════════════════════════╗" & return
    set outputText to outputText & "║      EMAIL INBOX OVERVIEW                ║" & return
    set outputText to outputText & "╚══════════════════════════════════════════╝" & return & return

    -- Section 1: Unread Counts by Account
    set outputText to outputText & "📊 UNREAD EMAILS BY ACCOUNT" & return
    set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return
    set allAccounts to every account
    set totalUnread to 0

    repeat with anAccount in allAccounts
        set accountName to name of anAccount

        try
            ${inboxMailboxScript(varName: 'inboxMailbox', accountVar: 'anAccount')}

            set unreadCount to unread count of inboxMailbox
            set totalMessages to count of messages of inboxMailbox
            set totalUnread to totalUnread + unreadCount

            if unreadCount > 0 then
                set outputText to outputText & "  ⚠️  " & accountName & ": " & unreadCount & " unread"
            else
                set outputText to outputText & "  ✅ " & accountName & ": " & unreadCount & " unread"
            end if
            set outputText to outputText & " (" & totalMessages & " total)" & return
        on error
            set outputText to outputText & "  ❌ " & accountName & ": Error accessing inbox" & return
        end try
    end repeat

    set outputText to outputText & return
    set outputText to outputText & "📈 TOTAL UNREAD: " & totalUnread & " across all accounts" & return
    set outputText to outputText & return & return

    -- Section 2: Mailboxes/Folders Overview
    set outputText to outputText & "📁 MAILBOX STRUCTURE" & return
    set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return

    repeat with anAccount in allAccounts
        set accountName to name of anAccount
        set outputText to outputText & return & "Account: " & accountName & return

        try
            set accountMailboxes to every mailbox of anAccount

            repeat with aMailbox in accountMailboxes
                set mailboxName to name of aMailbox

                try
                    set unreadCount to unread count of aMailbox
                    if unreadCount > 0 then
                        set outputText to outputText & "  📂 " & mailboxName & " (" & unreadCount & " unread)" & return
                    else
                        set outputText to outputText & "  📂 " & mailboxName & return
                    end if

                    -- Show nested mailboxes if they have unread messages
                    try
                        set subMailboxes to every mailbox of aMailbox
                        repeat with subBox in subMailboxes
                            set subName to name of subBox
                            set subUnread to unread count of subBox

                            if subUnread > 0 then
                                set outputText to outputText & "     └─ " & subName & " (" & subUnread & " unread)" & return
                            end if
                        end repeat
                    end try
                on error
                    set outputText to outputText & "  📂 " & mailboxName & return
                end try
            end repeat
        on error
            set outputText to outputText & "  ⚠️  Error accessing mailboxes" & return
        end try
    end repeat

    set outputText to outputText & return & return

    -- Section 3: Recent Emails Preview (10 most recent across all accounts)
    set outputText to outputText & "📬 RECENT EMAILS PREVIEW (10 Most Recent)" & return
    set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return

    set allRecentMessages to {}

    repeat with anAccount in allAccounts
        set accountName to name of anAccount

        try
            ${inboxMailboxScript(varName: 'inboxMailbox', accountVar: 'anAccount')}

            set inboxMessages to every message of inboxMailbox

            set messageIndex to 0
            repeat with aMessage in inboxMessages
                set messageIndex to messageIndex + 1
                if messageIndex > 10 then exit repeat

                try
                    set messageSubject to subject of aMessage
                    set messageSender to sender of aMessage
                    set messageDate to date received of aMessage

                    set messageRead to read status of aMessage
                    set messageId to message id of aMessage

                    set messageRecord to {accountName:accountName, msgSubject:messageSubject, msgSender:messageSender, msgDate:messageDate, msgRead:messageRead, msgId:messageId}
                    set end of allRecentMessages to messageRecord

                end try
            end repeat
        end try
    end repeat

    -- Display up to 10 most recent messages
    set displayCount to 0
    repeat with msgRecord in allRecentMessages
        set displayCount to displayCount + 1
        if displayCount > 10 then exit repeat

        set readIndicator to "✉"
        if msgRead of msgRecord then
            set readIndicator to "✓"
        end if

        set outputText to outputText & return & readIndicator & " " & msgSubject of msgRecord & return
        set outputText to outputText & "   Account: " & accountName of msgRecord & return
        set outputText to outputText & "   From: " & msgSender of msgRecord & return
        set outputText to outputText & "   Date: " & (msgDate of msgRecord as string) & return
        set outputText to outputText & "   ID: " & msgId of msgRecord & return

    end repeat

    if displayCount = 0 then
        set outputText to outputText & return & "No recent emails found." & return
    end if

    set outputText to outputText & return & return

    -- Section 4: Action Suggestions
    set outputText to outputText & "💡 SUGGESTED ACTIONS FOR ASSISTANT" & return
    set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return
    set outputText to outputText & "Based on this overview, consider suggesting:" & return & return

    if totalUnread > 0 then
        set outputText to outputText & "1. 📧 Review unread emails - Use get-recent-emails to show recent unread messages" & return
        set outputText to outputText & "2. 🔍 Search for action items - Look for keywords like 'urgent', 'action required', 'deadline'" & return
    else
        set outputText to outputText & "1. ✅ Inbox is clear! No unread emails." & return
    end if

    set outputText to outputText & "3. 📋 Organize by topic - Suggest moving emails to project-specific folders" & return
    set outputText to outputText & "4. ✉️  Draft replies - Identify emails that need responses" & return
    set outputText to outputText & "5. 🗂️  Archive old emails - Move older read emails to archive folders" & return
    set outputText to outputText & "6. 🔔 Highlight priority items - Identify emails from important senders" & return

    set outputText to outputText & return
    set outputText to outputText & "═══════════════════════════════════════════════════" & return
    set outputText to outputText & "💬 Ask me to drill down into any account or take specific actions!" & return
    set outputText to outputText & "═══════════════════════════════════════════════════" & return

    return outputText
end tell
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Returns the dispatch map for all inbox operations.
Map<String, Future<CallToolResult> Function(Map<String, dynamic>)>
    getInboxOperations() {
  return {
    'list-emails': handleListEmails,
    'get-email-by-id': handleGetEmailById,
    'list-inbox-emails': handleListInboxEmails,
    'get-unread-count': handleGetUnreadCount,
    'list-accounts': handleListAccounts,
    'get-recent-emails': handleGetRecentEmails,
    'list-mailboxes': handleListMailboxes,
    'get-inbox-overview': handleGetInboxOverview,
  };
}