// Batched classify-emails handler with progress between phases.
//
// Sends progress notifications between the AppleScript email fetch phase
// and the BM25 classification phase, enabling the client to see when
// each phase starts. Results are written to session chunks for polling.

import 'dart:convert';

import 'package:bm25/bm25.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../core.dart';

/// Batched classify-emails handler with progress between phases.
///
/// Same logic as [handleClassifyEmails] but writes to session chunks
/// and sends progress notifications between the AppleScript fetch
/// phase and the BM25 classification phase.
Future<void> runBatchedClassifyEmails({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final classifiersJson = args['classifiers'] as String;
  final account = args['account'] as String?;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final daysBack = args['days_back'] as int? ?? 30;
  final maxResults = args['max_results'] as int? ?? 200;
  final minScore = (args['min_score'] as num?)?.toDouble() ?? 0.0;
  final searchField = args['search_field'] as String? ?? 'all';
  final includeUnmatched = args['include_unmatched'] as bool? ?? true;

  // Parse classifiers (already validated in server.dart)
  final classifiersRaw = jsonDecode(classifiersJson) as Map<String, dynamic>;
  final classifiers = <String, List<String>>{};
  for (final entry in classifiersRaw.entries) {
    classifiers[entry.key] = (entry.value as List).cast<String>();
  }

  final escapedMailbox = escapeAppleScript(mailbox);

  // Build account targeting
  String accountScript;
  if (account != null) {
    final escapedAccount = escapeAppleScript(account);
    accountScript =
        '        set targetAccounts to {account "$escapedAccount"}\n';
  } else {
    accountScript = '        set targetAccounts to every account\n';
  }

  // Build date filter
  final dateSetup = daysBack > 0
      ? 'set cutoffDate to (current date) - ($daysBack * days)'
      : '';
  final dateCheck = daysBack > 0 ? 'messageDate > cutoffDate' : '';
  final dateCheckScript = dateCheck.isNotEmpty
      ? '''
                            if not ($dateCheck) then
                                set skipMessage to true
                            end if'''
      : '';

  // Build mailbox resolution
  String mailboxScript;
  if (mailbox == 'All') {
    mailboxScript =
        '                set searchMailboxes to every mailbox of anAccount\n';
  } else {
    mailboxScript = '''
                try
                    set searchMailbox to mailbox "$escapedMailbox" of anAccount
                on error
                    if "$escapedMailbox" is "INBOX" then
                        set searchMailbox to mailbox "Inbox" of anAccount
                    else
                        set searchMailbox to missing value
                    end if
                end try
                if searchMailbox is missing value then
                    set searchMailboxes to {}
                else
                    set searchMailboxes to {searchMailbox}
                end if
''';
  }

  // --- Phase 1: Fetch emails via AppleScript ---
  await extra.sendProgress(0, message: 'Fetching emails for classification...');

  final script = '''
tell application "Mail"
    set outputLines to {}
    set emailCount to 0
    $dateSetup

    try
        $accountScript

        repeat with anAccount in targetAccounts
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
                            if emailCount >= $maxResults then exit repeat
                            try
                                set skipMessage to false
                                set messageDate to date received of aMessage
                                $dateCheckScript
                                if not skipMessage then
                                    set messageSubject to subject of aMessage
                                    set messageSender to sender of aMessage
                                    set messageId to message id of aMessage
                                    set emailLine to messageSubject & "|" & messageSender & "|" & (messageDate as string) & "|" & messageId
                                    set end of outputLines to emailLine
                                    set emailCount to emailCount + 1
                                end if
                            end try
                        end repeat
                    end if
                on error
                    -- Skip problematic mailboxes
                end try
                if emailCount >= $maxResults then exit repeat
            end repeat
            if emailCount >= $maxResults then exit repeat
        end repeat

    on error errMsg
        return "ERROR:" & errMsg
    end try

    set AppleScript's text item delimiters to linefeed
    set outputText to outputLines as string
    set AppleScript's text item delimiters to ""
    return outputText
end tell
''';

  String rawOutput;
  try {
    rawOutput = await runAppleScript(script);
  } catch (e) {
    session.chunks.add('ERROR: Failed to fetch emails: $e\n');
    session.isComplete = true;
    await extra.sendProgress(1, message: 'classify-emails failed');
    return;
  }

  if (rawOutput.startsWith('ERROR:')) {
    session.chunks.add('ERROR: ${rawOutput.substring(6)}\n');
    session.isComplete = true;
    await extra.sendProgress(1, message: 'classify-emails failed');
    return;
  }

  // Parse pipe-delimited output
  final emails = <Map<String, String>>[];
  if (rawOutput.trim().isNotEmpty) {
    for (final line in rawOutput.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('|');
      if (parts.length >= 4) {
        emails.add({
          'subject': parts[0],
          'sender': parts[1],
          'date': parts[2],
          'message_id': parts.sublist(3).join('|'),
        });
      }
    }
  }

  if (emails.isEmpty) {
    final output = {
      'summary': <String, int>{},
      'categories': <String, List<Map<String, dynamic>>>{},
      if (includeUnmatched) 'unmatched': <Map<String, dynamic>>[],
      'total_emails_scanned': 0,
    };
    session.chunks
        .add(const JsonEncoder.withIndent('  ').convert(output));
    session.isComplete = true;
    await extra.sendProgress(1, message: 'classify-emails completed');
    return;
  }

  // --- Phase 2: BM25 classification ---
  await extra.sendProgress(0,
      message: 'Fetched ${emails.length} emails, running classification '
          'across ${classifiers.length} categories...');

  final documents = <BM25Document>[];
  for (var i = 0; i < emails.length; i++) {
    final email = emails[i];
    String text;
    switch (searchField) {
      case 'subject':
        text = email['subject'] ?? '';
      case 'sender':
        text = email['sender'] ?? '';
      default:
        text = '${email['subject'] ?? ''} ${email['sender'] ?? ''}';
    }
    documents.add(BM25Document(id: i, text: text, terms: []));
  }

  final bm25 = await BM25.build(documents);

  final categorizedResults = <String, List<Map<String, dynamic>>>{};
  final matchedIds = <int>{};

  for (final entry in classifiers.entries) {
    final category = entry.key;
    final terms = entry.value;
    final query = terms.join(' ');
    final results = await bm25.search(query, limit: maxResults);
    final categoryMatches = <Map<String, dynamic>>[];

    for (final result in results) {
      if (result.score < minScore) continue;
      final email = emails[result.doc.id];
      matchedIds.add(result.doc.id);
      categoryMatches.add({
        ...email,
        'score': double.parse(result.score.toStringAsFixed(3)),
      });
    }

    if (categoryMatches.isNotEmpty) {
      categorizedResults[category] = categoryMatches;
    }
  }

  // Build output
  final summary = <String, int>{};
  for (final entry in categorizedResults.entries) {
    summary[entry.key] = entry.value.length;
  }

  final unmatched = <Map<String, dynamic>>[];
  if (includeUnmatched) {
    for (var i = 0; i < emails.length; i++) {
      if (!matchedIds.contains(i)) {
        unmatched.add(emails[i]);
      }
    }
    summary['unmatched'] = unmatched.length;
  }

  final output = {
    'summary': summary,
    'categories': categorizedResults,
    if (includeUnmatched) 'unmatched': unmatched,
    'total_emails_scanned': emails.length,
  };

  await bm25.dispose();

  session.chunks
      .add(const JsonEncoder.withIndent('  ').convert(output));
  session.isComplete = true;
  await extra.sendProgress(1, message: 'classify-emails completed');
}
