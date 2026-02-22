// Core helpers: AppleScript execution, escaping, parsing, template snippets.
//
// Ported from Python apple-mail-mcp/core.py.

import 'dart:convert';
import 'dart:io';

/// Runs an AppleScript snippet via `osascript -` on stdin.
///
/// Returns the stdout output. Throws on non-zero exit or timeout.
Future<String> runAppleScript(String script) async {
  final process = await Process.start('osascript', ['-']);

  process.stdin.write(script);
  await process.stdin.close();

  final stdout = StringBuffer();
  final stderr = StringBuffer();

  process.stdout
      .transform(utf8.decoder)
      .listen((data) => stdout.write(data));
  process.stderr
      .transform(utf8.decoder)
      .listen((data) => stderr.write(data));

  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 120),
    onTimeout: () {
      process.kill();
      throw Exception('AppleScript timed out after 120 seconds');
    },
  );

  if (exitCode != 0) {
    throw Exception(
      'AppleScript failed (exit $exitCode): ${stderr.toString().trim()}',
    );
  }

  return stdout.toString().trim();
}

/// Escapes a string for safe inclusion inside AppleScript double-quoted strings.
String escapeAppleScript(String value) {
  return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}

/// Parses the pipe-delimited email list output from AppleScript into
/// a list of maps with keys like 'account', 'subject', 'sender', 'date'.
List<Map<String, String>> parseEmailList(String output) {
  if (output.trim().isEmpty) return [];

  final results = <Map<String, String>>[];
  Map<String, String>? current;

  for (final line in output.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    // A new email entry starts with ✉ or ✓
    if (trimmed.startsWith('✉') || trimmed.startsWith('✓')) {
      if (current != null) results.add(current);
      current = {
        'read': trimmed.startsWith('✓') ? 'true' : 'false',
        'subject': trimmed.substring(2).trim(),
      };
    } else if (current != null) {
      if (trimmed.startsWith('From: ')) {
        current['sender'] = trimmed.substring(6).trim();
      } else if (trimmed.startsWith('Date: ')) {
        current['date'] = trimmed.substring(6).trim();
      } else if (trimmed.startsWith('Account: ')) {
        current['account'] = trimmed.substring(9).trim();
      } else if (trimmed.startsWith('Mailbox: ')) {
        current['mailbox'] = trimmed.substring(9).trim();
      } else if (trimmed.startsWith('Preview: ') ||
          trimmed.startsWith('Content: ')) {
        current['preview'] = trimmed.substring(trimmed.indexOf(' ') + 1).trim();
      }
    }
  }

  if (current != null) results.add(current);
  return results;
}

// ──────────────────────────── Template helpers ────────────────────────────

/// AppleScript handler for case-insensitive string comparison.
const String lowercaseHandler = '''
on lowercase(theText)
    set lowText to do shell script "echo " & quoted form of theText & " | tr '[:upper:]' '[:lower:]'"
    return lowText
end lowercase
''';

/// AppleScript snippet that resolves the inbox mailbox for a given account,
/// falling back from "INBOX" to "Inbox".
String inboxMailboxScript({
  required String varName,
  required String accountVar,
}) {
  return '''
try
    set $varName to mailbox "INBOX" of $accountVar
on error
    try
        set $varName to mailbox "Inbox" of $accountVar
    on error
        error "Could not find INBOX mailbox"
    end try
end try
''';
}

/// AppleScript snippet that extracts a content preview, truncated to
/// [maxLength] characters.
String contentPreviewScript({
  int maxLength = 200,
  String outputVar = 'outputText',
}) {
  return '''
try
    set msgContent to content of aMessage
    set AppleScript's text item delimiters to {return, linefeed}
    set contentParts to text items of msgContent
    set AppleScript's text item delimiters to " "
    set cleanText to contentParts as string
    set AppleScript's text item delimiters to ""
    if length of cleanText > $maxLength then
        set contentPreview to text 1 thru $maxLength of cleanText & "..."
    else
        set contentPreview to cleanText
    end if
    set $outputVar to $outputVar & "   Content: " & contentPreview & return
on error
    set $outputVar to $outputVar & "   Content: [Not available]" & return
end try
''';
}

/// AppleScript snippet that sets a `targetDate` variable for date filtering.
/// Returns an empty string when [daysBack] <= 0 (no filter).
String dateCutoffScript({required int daysBack}) {
  if (daysBack <= 0) return '';
  return 'set targetDate to (current date) - ($daysBack * days)';
}

/// AppleScript condition fragment that skips system folders listed in
/// [skipFolders] from constants.dart.
String skipFoldersCondition() {
  final folders =
      ['Trash', 'Junk', 'Spam', 'Sent', 'Sent Messages', 'Drafts',
       'Deleted Messages', 'Deleted Items', 'Archive', 'Notes']
          .map((f) => '"$f"')
          .join(', ');
  return 'if mailboxName is not in {$folders} then';
}
