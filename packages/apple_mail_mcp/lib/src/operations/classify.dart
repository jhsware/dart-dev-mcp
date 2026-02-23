// Email classification using BM25 ranked matching.
//
// The LLM provides classifiers (category→terms mapping) at query time.
// The MCP fetches emails, builds a BM25 index, and returns scored,
// categorized results.

import 'dart:convert';

import 'package:bm25/bm25.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../core.dart';

/// Handles the classify-emails operation.
///
/// Accepts LLM-provided classifiers (a JSON object mapping category names
/// to arrays of search terms), fetches emails from Apple Mail, builds a
/// BM25 index, and returns results ranked and grouped by category.
Future<CallToolResult> handleClassifyEmails(
    Map<String, dynamic> args) async {
  final classifiersJson = args['classifiers'] as String?;
  final account = args['account'] as String?;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final daysBack = args['days_back'] as int? ?? 30;
  final maxResults = args['max_results'] as int? ?? 200;
  final minScore = (args['min_score'] as num?)?.toDouble() ?? 0.0;
  final searchField = args['search_field'] as String? ?? 'all';
  final includeUnmatched = args['include_unmatched'] as bool? ?? true;

  // Validate classifiers
  if (classifiersJson == null || classifiersJson.isEmpty) {
    return actionableError(
      'classifiers parameter is required.',
      'Provide a JSON object mapping category names to arrays of search '
          'terms, e.g. {"invoice": ["invoice", "faktura", "bill"]}.',
    );
  }

  Map<String, dynamic> classifiersRaw;
  try {
    classifiersRaw = jsonDecode(classifiersJson) as Map<String, dynamic>;
  } catch (e) {
    return actionableError(
      'Invalid classifiers JSON: $e',
      'Use format: {"category": ["term1", "term2"]}',
    );
  }

  if (classifiersRaw.isEmpty) {
    return actionableError(
      'classifiers must contain at least one category.',
      'Provide at least one category with search terms.',
    );
  }

  // Parse and validate classifier entries
  final classifiers = <String, List<String>>{};
  for (final entry in classifiersRaw.entries) {
    if (entry.value is! List) {
      return actionableError(
        'Category "${entry.key}" value must be a list of strings.',
        'Use format: {"category": ["term1", "term2"]}',
      );
    }
    final terms = (entry.value as List).cast<String>();
    if (terms.isEmpty) {
      return actionableError(
        'Category "${entry.key}" must have at least one search term.',
        'Provide search terms for each category.',
      );
    }
    classifiers[entry.key] = terms;
  }

  // Validate search_field
  if (!['all', 'subject', 'sender'].contains(searchField)) {
    return actionableError(
      'Invalid search_field "$searchField".',
      'Use "all", "subject", or "sender".',
    );
  }

  final escapedMailbox = escapeAppleScript(mailbox);

  // Build account targeting
  String accountScript;
  if (account != null) {
    final escapedAccount = escapeAppleScript(account);
    accountScript = '''
        set targetAccounts to {account "$escapedAccount"}
''';
  } else {
    accountScript = '''
        set targetAccounts to every account
''';
  }

  // Build date filter
  final dateSetup = daysBack > 0
      ? 'set cutoffDate to (current date) - ($daysBack * days)'
      : '';
  final dateCheck = daysBack > 0 ? 'messageDate > cutoffDate' : '';

  // Build date check script for inside the loop
  final dateCheckScript = dateCheck.isNotEmpty
      ? '''
                            if not ($dateCheck) then
                                set skipMessage to true
                            end if'''
      : '';

  // Build mailbox resolution per account
  String mailboxScript;
  if (mailbox == 'All') {
    mailboxScript = '''
                set searchMailboxes to every mailbox of anAccount
''';
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

  // AppleScript to fetch emails with pipe-delimited output
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

                                    -- Pipe-delimited: subject|sender|date|message_id
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

    -- Join with newline
    set AppleScript's text item delimiters to linefeed
    set outputText to outputLines as string
    set AppleScript's text item delimiters to ""
    return outputText
end tell
''';

  // Phase 1: Fetch emails
  String rawOutput;
  try {
    rawOutput = await runAppleScript(script);
  } catch (e) {
    return actionableError(
      'Failed to fetch emails: $e',
      'Check that Apple Mail is running and the account exists.',
    );
  }

  if (rawOutput.startsWith('ERROR:')) {
    return actionableError(rawOutput.substring(6), '');
  }

  // Parse pipe-delimited output into email maps
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
          'message_id': parts.sublist(3).join('|'), // message_id may contain |
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
    return CallToolResult.fromContent([
      TextContent(text: const JsonEncoder.withIndent('  ').convert(output)),
    ]);
  }

  // Phase 2: Build BM25 index
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
    documents.add(BM25Document(
      id: i,
      text: text,
      terms: [], // auto-tokenized by bm25
    ));
  }

  final bm25 = await BM25.build(documents);

  // Phase 3: Search per category
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

  // Phase 4: Build output
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

  return CallToolResult.fromContent([
    TextContent(text: const JsonEncoder.withIndent('  ').convert(output)),
  ]);
}

/// Returns the dispatch map for classify operations.
Map<String, Future<CallToolResult> Function(Map<String, dynamic>)>
    getClassifyOperations() {
  return {
    'classify-emails': handleClassifyEmails,
  };
}
