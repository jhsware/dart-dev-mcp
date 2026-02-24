// Batched handler for list-email-attachments operation.
//
// The synchronous version scans the entire inbox in a single AppleScript
// call, which can cause MCP transport timeouts on large mailboxes.
// This batched version uses fetchMessageIds + batch processing for
// progressive output and cancellation support.

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../core.dart';
import '../batch_helpers.dart';

/// Batch size for attachment listing (slower per message, so same 200).
const _batchSize = 200;

/// Batched list-email-attachments handler.
///
/// Lists attachments with names and sizes for emails matching a subject
/// keyword. Uses fetchMessageIds + batch processing to avoid timeouts.
Future<void> runBatchedListEmailAttachments({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final account = args['account'] as String;
  final subjectKeyword = args['subject_keyword'] as String;
  final maxResults = args['max_results'] as int? ?? 1;

  final escapedAccount = escapeAppleScript(account);
  final escapedKeyword = escapeAppleScript(subjectKeyword);

  // Write header chunk
  session.chunks.add(
    'ATTACHMENTS FOR: $subjectKeyword\n\n',
  );

  // Fetch message IDs from INBOX
  await extra.sendProgress(0, message: 'Fetching message IDs...');
  final allIds = await fetchMessageIds(
    account: account,
    mailbox: 'INBOX',
  );

  if (allIds.isEmpty) {
    session.chunks.add(
      '========================================\n'
      'FOUND: 0 matching email(s)\n'
      '========================================\n',
    );
    session.isComplete = true;
    await extra.sendProgress(1, message: 'list-email-attachments completed');
    return;
  }

  await extra.sendProgress(0,
      message: 'Found ${allIds.length} messages to search');

  // Process in batches
  final batches = batchList(allIds, _batchSize);
  var resultCount = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return; // cancelled
    if (resultCount >= maxResults) break;

    final batch = batches[i];
    final idSet = buildMessageIdSet(batch);

    // This script finds emails matching the keyword in this batch
    // and returns their attachment details in pipe-delimited format.
    // Each matching email outputs one line:
    //   subject|sender|date|attachmentCount|att1Name:att1SizeKB,att2Name:att2SizeKB,...
    final script = '''
$lowercaseHandler

tell application "Mail"
    set outputText to ""
    set targetAccount to account "$escapedAccount"
    set idSet to $idSet

    ${_inboxLoopStart(escapedAccount)}
                    set mailboxMessages to every message of currentMailbox
                    repeat with aMessage in mailboxMessages
                        try
                            set msgId to message id of aMessage
                            if msgId is in idSet then
                                set messageSubject to subject of aMessage
                                set lowerSubject to my lowercase(messageSubject)
                                set lowerKeyword to my lowercase("$escapedKeyword")
                                if lowerSubject contains lowerKeyword then
                                    set messageSender to sender of aMessage
                                    set messageDate to date received of aMessage
                                    set msgAttachments to mail attachments of aMessage
                                    set attachmentCount to count of msgAttachments
                                    set attachmentDetails to ""
                                    repeat with anAttachment in msgAttachments
                                        set attachmentFileName to name of anAttachment
                                        try
                                            set attachmentSize to size of anAttachment
                                            set sizeInKB to (attachmentSize / 1024) as integer
                                            set attachmentDetails to attachmentDetails & attachmentFileName & ":" & sizeInKB & ","
                                        on error
                                            set attachmentDetails to attachmentDetails & attachmentFileName & ":0,"
                                        end try
                                    end repeat
                                    set outputText to outputText & messageSubject & "|" & messageSender & "|" & (messageDate as string) & "|" & attachmentCount & "|" & attachmentDetails & linefeed
                                end if
                            end if
                        end try
                    end repeat
    ${_inboxLoopEnd()}

    return outputText
end tell
''';

    try {
      final result = await runAppleScript(script);
      final lines = _parseLines(result);

      final batchOutput = StringBuffer();
      for (final line in lines) {
        final parts = line.split('|');
        if (parts.length >= 4) {
          resultCount++;
          if (resultCount <= maxResults) {
            final subject = parts[0];
            final senderVal = parts[1];
            final date = parts[2];
            final attachmentCount = parts[3];
            final attachmentDetails =
                parts.length > 4 ? parts[4] : '';

            batchOutput.writeln('✉ $subject');
            batchOutput.writeln('   From: $senderVal');
            batchOutput.writeln('   Date: $date');
            batchOutput.writeln();

            if (attachmentCount != '0' && attachmentDetails.isNotEmpty) {
              batchOutput
                  .writeln('   Attachments ($attachmentCount):');
              // Parse attachment details: "name:sizeKB,name:sizeKB,"
              final attachments = attachmentDetails
                  .split(',')
                  .where((a) => a.isNotEmpty);
              for (final att in attachments) {
                final attParts = att.split(':');
                final name = attParts[0];
                final sizeKB =
                    attParts.length > 1 ? attParts[1] : '0';
                if (sizeKB != '0') {
                  batchOutput
                      .writeln('   📎 $name ($sizeKB KB)');
                } else {
                  batchOutput.writeln('   📎 $name');
                }
              }
            } else {
              batchOutput.writeln('   No attachments');
            }

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
            'found $resultCount matches');
  }

  session.chunks.add(
    '========================================\n'
    'FOUND: $resultCount matching email(s)\n'
    '========================================\n',
  );
  session.isComplete = true;
  await extra.sendProgress(1, message: 'list-email-attachments completed');
}

// ─────────────────────── AppleScript helpers ───────────────────────

/// Parses AppleScript output into non-empty trimmed lines.
Iterable<String> _parseLines(String result) {
  return result.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
}

/// Generates AppleScript to resolve INBOX and start the message loop.
///
/// Attachment operations only search INBOX (matching the sync handler),
/// so this is a simplified version of the general mailbox loop.
String _inboxLoopStart(String escapedAccount) {
  return '''
    try
        set searchMailbox to mailbox "INBOX" of targetAccount
    on error
        set searchMailbox to mailbox "Inbox" of targetAccount
    end try
    set searchMailboxes to {searchMailbox}
    repeat with currentMailbox in searchMailboxes
        try
            if true then''';
}

/// Generates the AppleScript mailbox loop end.
String _inboxLoopEnd() {
  return '''
                end if
            end try
        end repeat''';
}
