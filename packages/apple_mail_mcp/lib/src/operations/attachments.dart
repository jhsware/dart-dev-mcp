// Attachment & analytics operations: saving, listing, stats, and export.
//
// Ported from Python apple-mail-mcp manage.py (save_email_attachment) and
// analytics.py (list_email_attachments, get_statistics, export_emails).
// All operations are read-only — no email mutations.

import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import '../core.dart';

/// Expands `~` in a path to the user's home directory.
String _expandHome(String path) {
  if (path.startsWith('~')) {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return home + path.substring(1);
  }
  return path;
}

/// Handles the save-email-attachment operation.
///
/// Saves a specific attachment from an email to disk (read from mail,
/// write to filesystem — does NOT modify the email).
Future<CallToolResult> handleSaveEmailAttachment(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return actionableError(
      'account parameter is required for save-email-attachment.',
      'Use list-accounts to see available accounts.',
    );
  }

  final subjectKeyword = args['subject_keyword'] as String?;
  if (subjectKeyword == null) {
    return actionableError(
      'subject_keyword parameter is required for save-email-attachment.',
      'Provide a keyword to match the email subject containing the attachment.',
    );
  }

  final attachmentName = args['attachment_name'] as String? ?? '';
  final savePath =
      args['save_directory'] as String? ?? '~/Desktop';
  final expandedPath = _expandHome(savePath);

  final escapedAccount = escapeAppleScript(account);
  final escapedKeyword = escapeAppleScript(subjectKeyword);
  final escapedAttachment = escapeAppleScript(attachmentName);
  final escapedPath = escapeAppleScript(expandedPath);

  final script = '''
tell application "Mail"
    set outputText to ""

    try
        set targetAccount to account "$escapedAccount"
        ${inboxMailboxScript(varName: 'inboxMailbox', accountVar: 'targetAccount')}
        set inboxMessages to every message of inboxMailbox
        set foundAttachment to false

        repeat with aMessage in inboxMessages
            try
                set messageSubject to subject of aMessage

                if messageSubject contains "$escapedKeyword" then
                    set msgAttachments to mail attachments of aMessage

                    repeat with anAttachment in msgAttachments
                        set attachmentFileName to name of anAttachment

                        if attachmentFileName contains "$escapedAttachment" then
                            save anAttachment in POSIX file "$escapedPath"

                            set outputText to "✓ Attachment saved successfully!" & return & return
                            set outputText to outputText & "Email: " & messageSubject & return
                            set outputText to outputText & "Attachment: " & attachmentFileName & return
                            set outputText to outputText & "Saved to: $escapedPath" & return

                            set foundAttachment to true
                            exit repeat
                        end if
                    end repeat

                    if foundAttachment then exit repeat
                end if
            end try
        end repeat

        if not foundAttachment then
            set outputText to "⚠ Attachment not found" & return
            set outputText to outputText & "Email keyword: $escapedKeyword" & return
            set outputText to outputText & "Attachment name: $escapedAttachment" & return
        end if

    on error errMsg
        return "Error: " & errMsg
    end try

    return outputText
end tell
''';

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Handles the list-email-attachments operation.
///
/// Lists attachments with names and sizes for emails matching a subject.
Future<CallToolResult> handleListEmailAttachments(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return actionableError(
      'account parameter is required for list-email-attachments.',
      'Use list-accounts to see available accounts.',
    );
  }

  final subjectKeyword = args['subject_keyword'] as String?;
  if (subjectKeyword == null) {
    return actionableError(
      'subject_keyword parameter is required for list-email-attachments.',
      'Provide a keyword to match the email subject.',
    );
  }

  final maxResults = args['max_results'] as int? ?? 1;

  final escapedKeyword = escapeAppleScript(subjectKeyword);
  final escapedAccount = escapeAppleScript(account);

  final script = '''
tell application "Mail"
    set outputText to "ATTACHMENTS FOR: $escapedKeyword" & return & return
    set resultCount to 0

    try
        set targetAccount to account "$escapedAccount"
        ${inboxMailboxScript(varName: 'inboxMailbox', accountVar: 'targetAccount')}
        set inboxMessages to every message of inboxMailbox

        repeat with aMessage in inboxMessages
            if resultCount >= $maxResults then exit repeat

            try
                set messageSubject to subject of aMessage

                if messageSubject contains "$escapedKeyword" then
                    set messageSender to sender of aMessage
                    set messageDate to date received of aMessage

                    set outputText to outputText & "✉ " & messageSubject & return
                    set outputText to outputText & "   From: " & messageSender & return
                    set outputText to outputText & "   Date: " & (messageDate as string) & return & return

                    set msgAttachments to mail attachments of aMessage
                    set attachmentCount to count of msgAttachments

                    if attachmentCount > 0 then
                        set outputText to outputText & "   Attachments (" & attachmentCount & "):" & return

                        repeat with anAttachment in msgAttachments
                            set attachmentName to name of anAttachment
                            try
                                set attachmentSize to size of anAttachment
                                set sizeInKB to (attachmentSize / 1024) as integer
                                set outputText to outputText & "   📎 " & attachmentName & " (" & sizeInKB & " KB)" & return
                            on error
                                set outputText to outputText & "   📎 " & attachmentName & return
                            end try
                        end repeat
                    else
                        set outputText to outputText & "   No attachments" & return
                    end if

                    set outputText to outputText & return
                    set resultCount to resultCount + 1
                end if
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

/// Handles the get-statistics operation.
///
/// Three sub-modes: account_overview, sender_stats, mailbox_breakdown.
Future<CallToolResult> handleGetStatistics(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return actionableError(
      'account parameter is required for get-statistics.',
      'Use list-accounts to see available accounts.',
    );
  }

  final scope = args['scope'] as String? ?? 'account_overview';
  final sender = args['sender'] as String?;
  final mailbox = args['mailbox'] as String?;
  final daysBack = args['days_back'] as int? ?? 30;

  final escapedAccount = escapeAppleScript(account);
  final escapedSender =
      sender != null ? escapeAppleScript(sender) : null;
  final escapedMailbox =
      mailbox != null ? escapeAppleScript(mailbox) : null;

  final dateFilter = daysBack > 0
      ? 'set targetDate to (current date) - ($daysBack * days)'
      : '';
  final dateCheck = daysBack > 0 ? 'and messageDate > targetDate' : '';

  String script;

  if (scope == 'account_overview') {
    script = '''
tell application "Mail"
    set outputText to "╔══════════════════════════════════════════╗" & return
    set outputText to outputText & "║      EMAIL STATISTICS - $escapedAccount       ║" & return
    set outputText to outputText & "╚══════════════════════════════════════════╝" & return & return

    $dateFilter

    try
        set targetAccount to account "$escapedAccount"
        set allMailboxes to every mailbox of targetAccount

        set totalEmails to 0
        set totalUnread to 0
        set totalRead to 0
        set totalFlagged to 0
        set totalWithAttachments to 0
        set senderCounts to {}
        set mailboxCounts to {}

        repeat with aMailbox in allMailboxes
            set mailboxName to name of aMailbox
            set mailboxMessages to every message of aMailbox
            set mailboxTotal to 0

            repeat with aMessage in mailboxMessages
                try
                    set messageDate to date received of aMessage

                    if true $dateCheck then
                        set totalEmails to totalEmails + 1
                        set mailboxTotal to mailboxTotal + 1

                        if read status of aMessage then
                            set totalRead to totalRead + 1
                        else
                            set totalUnread to totalUnread + 1
                        end if

                        try
                            if flagged status of aMessage then
                                set totalFlagged to totalFlagged + 1
                            end if
                        end try

                        set attachmentCount to count of mail attachments of aMessage
                        if attachmentCount > 0 then
                            set totalWithAttachments to totalWithAttachments + 1
                        end if

                        set messageSender to sender of aMessage
                        set senderFound to false
                        repeat with senderPair in senderCounts
                            if item 1 of senderPair is messageSender then
                                set item 2 of senderPair to (item 2 of senderPair) + 1
                                set senderFound to true
                                exit repeat
                            end if
                        end repeat
                        if not senderFound then
                            set end of senderCounts to {messageSender, 1}
                        end if
                    end if
                end try
            end repeat

            if mailboxTotal > 0 then
                set end of mailboxCounts to {mailboxName, mailboxTotal}
            end if
        end repeat

        set outputText to outputText & "📊 VOLUME METRICS" & return
        set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return
        set outputText to outputText & "Total Emails: " & totalEmails & return
        if totalEmails > 0 then
            set outputText to outputText & "Unread: " & totalUnread & " (" & (round ((totalUnread / totalEmails) * 100)) & "%)" & return
            set outputText to outputText & "Read: " & totalRead & " (" & (round ((totalRead / totalEmails) * 100)) & "%)" & return
            set outputText to outputText & "Flagged: " & totalFlagged & return
            set outputText to outputText & "With Attachments: " & totalWithAttachments & " (" & (round ((totalWithAttachments / totalEmails) * 100)) & "%)" & return
        else
            set outputText to outputText & "Unread: 0" & return
            set outputText to outputText & "Read: 0" & return
            set outputText to outputText & "Flagged: 0" & return
            set outputText to outputText & "With Attachments: 0" & return
        end if
        set outputText to outputText & return

        set outputText to outputText & "👥 TOP SENDERS" & return
        set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return
        set topCount to 0
        repeat with senderPair in senderCounts
            set topCount to topCount + 1
            if topCount > 5 then exit repeat
            set outputText to outputText & item 1 of senderPair & ": " & item 2 of senderPair & " emails" & return
        end repeat
        set outputText to outputText & return

        set outputText to outputText & "📁 MAILBOX DISTRIBUTION" & return
        set outputText to outputText & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" & return
        set topCount to 0
        repeat with mailboxPair in mailboxCounts
            set topCount to topCount + 1
            if topCount > 5 then exit repeat
            if totalEmails > 0 then
                set mailboxPercent to round ((item 2 of mailboxPair / totalEmails) * 100)
                set outputText to outputText & item 1 of mailboxPair & ": " & item 2 of mailboxPair & " (" & mailboxPercent & "%)" & return
            else
                set outputText to outputText & item 1 of mailboxPair & ": " & item 2 of mailboxPair & return
            end if
        end repeat

    on error errMsg
        return "Error: " & errMsg
    end try

    return outputText
end tell
''';
  } else if (scope == 'sender_stats') {
    if (escapedSender == null) {
      return actionableError(
        'sender parameter is required for get-statistics with sender_stats scope.',
        'Provide a sender name or email address.',
      );
    }

    script = '''
tell application "Mail"
    set outputText to "SENDER STATISTICS" & return & return
    set outputText to outputText & "Sender: $escapedSender" & return
    set outputText to outputText & "Account: $escapedAccount" & return & return

    $dateFilter

    try
        set targetAccount to account "$escapedAccount"
        set allMailboxes to every mailbox of targetAccount

        set totalFromSender to 0
        set unreadFromSender to 0
        set withAttachments to 0

        repeat with aMailbox in allMailboxes
            set mailboxMessages to every message of aMailbox

            repeat with aMessage in mailboxMessages
                try
                    set messageSender to sender of aMessage
                    set messageDate to date received of aMessage

                    if messageSender contains "$escapedSender" $dateCheck then
                        set totalFromSender to totalFromSender + 1

                        if not (read status of aMessage) then
                            set unreadFromSender to unreadFromSender + 1
                        end if

                        if (count of mail attachments of aMessage) > 0 then
                            set withAttachments to withAttachments + 1
                        end if
                    end if
                end try
            end repeat
        end repeat

        set outputText to outputText & "Total emails: " & totalFromSender & return
        set outputText to outputText & "Unread: " & unreadFromSender & return
        set outputText to outputText & "With attachments: " & withAttachments & return

    on error errMsg
        return "Error: " & errMsg
    end try

    return outputText
end tell
''';
  } else if (scope == 'mailbox_breakdown') {
    final mailboxParam = escapedMailbox ?? 'INBOX';

    script = '''
tell application "Mail"
    set outputText to "MAILBOX STATISTICS" & return & return
    set outputText to outputText & "Mailbox: $mailboxParam" & return
    set outputText to outputText & "Account: $escapedAccount" & return & return

    try
        set targetAccount to account "$escapedAccount"
        try
            set targetMailbox to mailbox "$mailboxParam" of targetAccount
        on error
            if "$mailboxParam" is "INBOX" then
                set targetMailbox to mailbox "Inbox" of targetAccount
            else
                error "Mailbox not found"
            end if
        end try

        set mailboxMessages to every message of targetMailbox
        set totalMessages to count of mailboxMessages
        set unreadMessages to unread count of targetMailbox

        set outputText to outputText & "Total messages: " & totalMessages & return
        set outputText to outputText & "Unread: " & unreadMessages & return
        set outputText to outputText & "Read: " & (totalMessages - unreadMessages) & return

    on error errMsg
        return "Error: " & errMsg
    end try

    return outputText
end tell
''';
  } else {
    return actionableError(
      "Invalid scope '$scope' for get-statistics.",
      'Use one of: account_overview, sender_stats, mailbox_breakdown.',
    );
  }

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Handles the export-emails operation.
///
/// Exports emails to files for backup or analysis.
Future<CallToolResult> handleExportEmails(
    Map<String, dynamic> args) async {
  final account = args['account'] as String?;
  if (account == null) {
    return actionableError(
      'account parameter is required for export-emails.',
      'Use list-accounts to see available accounts.',
    );
  }

  final scope = args['scope'] as String?;
  if (scope == null) {
    return actionableError(
      'scope parameter is required for export-emails.',
      'Use single_email or entire_mailbox.',
    );
  }

  final subjectKeyword = args['subject_keyword'] as String?;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final saveDirectory = args['save_directory'] as String? ?? '~/Desktop';
  final format = args['format'] as String? ?? 'txt';

  final saveDir = _expandHome(saveDirectory);
  final safeAccount = escapeAppleScript(account);
  final safeMailbox = escapeAppleScript(mailbox);
  final safeFormat = escapeAppleScript(format);
  final safeSaveDir = escapeAppleScript(saveDir);

  String script;

  if (scope == 'single_email') {
    if (subjectKeyword == null) {
      return actionableError(
        "subject_keyword parameter is required for export-emails with single_email scope.",
        "Provide a keyword to match the email subject to export.",
      );
    }

    final safeSubjectKeyword = escapeAppleScript(subjectKeyword);

    script = '''
tell application "Mail"
    set outputText to "EXPORTING EMAIL" & return & return

    try
        set targetAccount to account "$safeAccount"
        try
            set targetMailbox to mailbox "$safeMailbox" of targetAccount
        on error
            if "$safeMailbox" is "INBOX" then
                set targetMailbox to mailbox "Inbox" of targetAccount
            else
                error "Mailbox not found: $safeMailbox"
            end if
        end try

        set mailboxMessages to every message of targetMailbox
        set foundMessage to missing value

        repeat with aMessage in mailboxMessages
            try
                set messageSubject to subject of aMessage

                if messageSubject contains "$safeSubjectKeyword" then
                    set foundMessage to aMessage
                    exit repeat
                end if
            end try
        end repeat

        if foundMessage is not missing value then
            set messageSubject to subject of foundMessage
            set messageSender to sender of foundMessage
            set messageDate to date received of foundMessage
            set messageContent to content of foundMessage

            set safeSubject to messageSubject
            set AppleScript's text item delimiters to "/"
            set safeSubjectParts to text items of safeSubject
            set AppleScript's text item delimiters to "-"
            set safeSubject to safeSubjectParts as string
            set AppleScript's text item delimiters to ""

            set fileName to safeSubject & ".$safeFormat"
            set filePath to "$safeSaveDir/" & fileName

            if "$safeFormat" is "txt" then
                set exportContent to "Subject: " & messageSubject & return
                set exportContent to exportContent & "From: " & messageSender & return
                set exportContent to exportContent & "Date: " & (messageDate as string) & return & return
                set exportContent to exportContent & messageContent
            else if "$safeFormat" is "html" then
                set exportContent to "<html><body>"
                set exportContent to exportContent & "<h2>" & messageSubject & "</h2>"
                set exportContent to exportContent & "<p><strong>From:</strong> " & messageSender & "</p>"
                set exportContent to exportContent & "<p><strong>Date:</strong> " & (messageDate as string) & "</p>"
                set exportContent to exportContent & "<hr>" & messageContent
                set exportContent to exportContent & "</body></html>"
            end if

            set fileRef to open for access POSIX file filePath with write permission
            set eof of fileRef to 0
            write exportContent to fileRef as «class utf8»
            close access fileRef

            set outputText to outputText & "✓ Email exported successfully!" & return & return
            set outputText to outputText & "Subject: " & messageSubject & return
            set outputText to outputText & "Saved to: " & filePath & return

        else
            set outputText to outputText & "⚠ No email found matching: $safeSubjectKeyword" & return
        end if

    on error errMsg
        try
            close access file filePath
        end try
        return "Error: " & errMsg
    end try

    return outputText
end tell
''';
  } else if (scope == 'entire_mailbox') {
    script = '''
tell application "Mail"
    set outputText to "EXPORTING MAILBOX" & return & return

    try
        set targetAccount to account "$safeAccount"
        try
            set targetMailbox to mailbox "$safeMailbox" of targetAccount
        on error
            if "$safeMailbox" is "INBOX" then
                set targetMailbox to mailbox "Inbox" of targetAccount
            else
                error "Mailbox not found: $safeMailbox"
            end if
        end try

        set mailboxMessages to every message of targetMailbox
        set messageCount to count of mailboxMessages
        set exportCount to 0

        set exportDir to "$safeSaveDir/${safeMailbox}_export"
        do shell script "mkdir -p " & quoted form of exportDir

        repeat with aMessage in mailboxMessages
            try
                set messageSubject to subject of aMessage
                set messageSender to sender of aMessage
                set messageDate to date received of aMessage
                set messageContent to content of aMessage

                set exportCount to exportCount + 1
                set fileName to exportCount & "_" & messageSubject & ".$safeFormat"

                set AppleScript's text item delimiters to "/"
                set fileNameParts to text items of fileName
                set AppleScript's text item delimiters to "-"
                set fileName to fileNameParts as string
                set AppleScript's text item delimiters to ""

                set filePath to exportDir & "/" & fileName

                if "$safeFormat" is "txt" then
                    set exportContent to "Subject: " & messageSubject & return
                    set exportContent to exportContent & "From: " & messageSender & return
                    set exportContent to exportContent & "Date: " & (messageDate as string) & return & return
                    set exportContent to exportContent & messageContent
                else if "$safeFormat" is "html" then
                    set exportContent to "<html><body>"
                    set exportContent to exportContent & "<h2>" & messageSubject & "</h2>"
                    set exportContent to exportContent & "<p><strong>From:</strong> " & messageSender & "</p>"
                    set exportContent to exportContent & "<p><strong>Date:</strong> " & (messageDate as string) & "</p>"
                    set exportContent to exportContent & "<hr>" & messageContent
                    set exportContent to exportContent & "</body></html>"
                end if

                set fileRef to open for access POSIX file filePath with write permission
                set eof of fileRef to 0
                write exportContent to fileRef as «class utf8»
                close access fileRef

            on error
                -- Continue with next email if one fails
            end try
        end repeat

        set outputText to outputText & "✓ Mailbox exported successfully!" & return & return
        set outputText to outputText & "Mailbox: $safeMailbox" & return
        set outputText to outputText & "Total emails: " & messageCount & return
        set outputText to outputText & "Exported: " & exportCount & return
        set outputText to outputText & "Location: " & exportDir & return

    on error errMsg
        return "Error: " & errMsg
    end try

    return outputText
end tell
''';
  } else {
    return actionableError(
      "Invalid scope '$scope' for export-emails.",
      'Use one of: single_email, entire_mailbox.',
    );
  }

  final result = await runAppleScript(script);
  return CallToolResult.fromContent([TextContent(text: result)]);
}

/// Returns the dispatch map for all attachment & analytics operations.
Map<String, Future<CallToolResult> Function(Map<String, dynamic>)>
    getAttachmentOperations() {
  return {
    'save-email-attachment': handleSaveEmailAttachment,
    'list-email-attachments': handleListEmailAttachments,
    'get-statistics': handleGetStatistics,
    'export-emails': handleExportEmails,
  };
}
