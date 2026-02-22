// Inbox operations: listing, counting, and overview.
//
// Ported from Python apple-mail-mcp/apple_mail_mcp/tools/inbox.py.
// All operations are read-only.

import 'package:mcp_dart/mcp_dart.dart';

import '../core.dart';

/// Handles the list-inbox-emails operation.
///
/// Lists all inbox emails across all accounts or a specific one.
Future<CallToolResult> handleListInboxEmails(
    Map<String, dynamic> args) async {
  // account filtering not yet implemented; iterates all accounts
  final maxEmails = args['max_emails'] as int? ?? 0;
  final includeRead = args['include_read'] as bool? ?? true;

  final script = '''
tell application "Mail"
    set outputText to "INBOX EMAILS - ALL ACCOUNTS" & return & return
    set totalCount to 0
    set allAccounts to every account

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

                        if shouldInclude then
                            if messageRead then
                                set readIndicator to "✓"
                            else
                                set readIndicator to "✉"
                            end if

                            set outputText to outputText & readIndicator & " " & messageSubject & return
                            set outputText to outputText & "   From: " & messageSender & return
                            set outputText to outputText & "   Date: " & (messageDate as string) & return
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
    return CallToolResult.fromContent(
      [TextContent(text: 'Error: account parameter is required')],
    );
  }

  final count = args['count'] as int? ?? 10;
  final includeContent = args['include_content'] as bool? ?? false;
  final escapedAccount = escapeAppleScript(account);

  final contentScript = includeContent
      ? contentPreviewScript(maxLength: 200, outputVar: 'outputText')
      : '';

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

                $contentScript

                set outputText to outputText & return
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

                    set messageRecord to {accountName:accountName, msgSubject:messageSubject, msgSender:messageSender, msgDate:messageDate, msgRead:messageRead}
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
    'list-inbox-emails': handleListInboxEmails,
    'get-unread-count': handleGetUnreadCount,
    'list-accounts': handleListAccounts,
    'get-recent-emails': handleGetRecentEmails,
    'list-mailboxes': handleListMailboxes,
    'get-inbox-overview': handleGetInboxOverview,
  };
}
