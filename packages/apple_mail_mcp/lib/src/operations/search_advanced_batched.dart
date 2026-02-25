// Batched handler for get-email-thread operation.
//
// This operation previously ran synchronously, scanning the entire mailbox
// in a single AppleScript call. When called via MCP by an LLM, the
// client-side timeout (30-60s) triggers before the AppleScript finishes.
//
// Batching provides progressive output, cancellation support, and avoids
// MCP transport timeouts.

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../core.dart';
import '../batch_helpers.dart';
import '../constants.dart';

/// Batch size for subject-based searches (fast, so large batches).
const _batchSize = 200;

/// Batched get-email-thread handler.
///
/// Thread/conversation view with Re:/Fwd: prefix stripping.
/// Uses fetchMessageIds + batch processing to avoid timeouts.
Future<void> runBatchedGetEmailThread({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final account = args['account'] as String;
  final subjectKeyword = args['subject_keyword'] as String;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final maxMessages = args['max_messages'] as int? ?? 50;

  final escapedAccount = escapeAppleScript(account);
  final escapedMailbox = escapeAppleScript(mailbox);

  // Strip thread prefixes for matching (same logic as sync version)
  var cleanedKeyword = subjectKeyword;
  for (final prefix in threadPrefixes) {
    cleanedKeyword = cleanedKeyword.replaceAll(prefix, '').trim();
  }
  final escapedKeyword = escapeAppleScript(cleanedKeyword);

  // Write header chunk
  session.chunks.add(
    'EMAIL THREAD VIEW\n\n'
    'Thread topic: $cleanedKeyword\n'
    'Account: $account\n\n',
  );

  // Fetch message IDs
  await extra.sendProgress(0, message: 'Fetching message IDs...');
  final allIds = await fetchMessageIds(
    account: account,
    mailbox: mailbox,
  );

  if (allIds.isEmpty) {
    session.chunks.add(
      '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
      'FOUND 0 MESSAGE(S) IN THREAD\n'
      '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'get-email-thread completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${allIds.length} messages to search');

  // Process in batches
  final batches = batchList(allIds, _batchSize);
  var matchedCount = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return; // cancelled
    if (matchedCount >= maxMessages) break;

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
                                set messageSubject to subject of aMessage

                                set cleanSubject to messageSubject
                                if cleanSubject starts with "Re: " or cleanSubject starts with "RE: " then
                                    set cleanSubject to text 5 thru -1 of cleanSubject
                                end if
                                if cleanSubject starts with "Fwd: " or cleanSubject starts with "FW: " or cleanSubject starts with "Fw: " then
                                    set cleanSubject to text 6 thru -1 of cleanSubject
                                end if

                                set lowerCleanSubject to my lowercase(cleanSubject)
                                set lowerKeyword to my lowercase("$escapedKeyword")

                                if lowerCleanSubject contains lowerKeyword then
                                    set messageSender to sender of aMessage
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
      final lines = _parseLines(result);

      final batchOutput = StringBuffer();
      for (final line in lines) {
        final parts = line.split('|');
        if (parts.length >= 5) {
          matchedCount++;
          if (matchedCount <= maxMessages) {
            final readIndicator = parts[1] == 'read' ? '✓' : '✉';
            final subject = parts[2];
            final senderVal = parts[3];
            final date = parts[4];

            batchOutput.writeln('$readIndicator $subject');
            batchOutput.writeln('   From: $senderVal');
            batchOutput.writeln('   Date: $date');
            batchOutput.writeln('   ID: ${parts[0]}');
            batchOutput.writeln();
          }
        }
      }

      if (batchOutput.isNotEmpty) {
        session.chunks.add(batchOutput.toString());
      }
    } catch (e) {
      session.chunks.add('Warning: Batch ${i + 1} error: $e\n');
    }

    scanned += batch.length;
    await extra.sendProgress(0,
        message: 'Scanned $scanned of ${allIds.length} messages, '
            'found $matchedCount thread matches');
  }

  session.chunks.add(
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    'FOUND $matchedCount MESSAGE(S) IN THREAD\n'
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n',
  );
  session.isComplete = true;
  await extra.sendProgress(1, message: 'get-email-thread completed');
}

// ─────────────────────── AppleScript helpers ───────────────────────

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
