// Helpers for running mdfind and mdls commands against the macOS Spotlight
// index. These replace AppleScript-based message enumeration with fast
// Spotlight queries over .emlx files stored by Apple Mail.

import 'dart:convert';
import 'dart:io';

/// Default base directory for Apple Mail message storage.
const String defaultMailDirectory = '~/Library/Mail';

/// The Spotlight content type for Apple Mail .emlx files.
const String emlxContentType = 'com.apple.mail.emlx';

/// Runs `mdfind` with the given Spotlight query string.
///
/// Optionally scopes results to [directory] via the `-onlyin` flag.
/// Returns a list of absolute file paths (one per found item).
/// Empty results return an empty list; errors throw [Exception].
Future<List<String>> runMdfind(
  String query, {
  String? directory,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final args = <String>[];
  if (directory != null) {
    final expanded = _expandHome(directory);
    args.addAll(['-onlyin', expanded]);
  }
  args.add(query);

  final process = await Process.start('mdfind', args);

  final stdout = StringBuffer();
  final stderr = StringBuffer();

  process.stdout.transform(utf8.decoder).listen((d) => stdout.write(d));
  process.stderr.transform(utf8.decoder).listen((d) => stderr.write(d));

  final exitCode = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      process.kill();
      throw Exception('mdfind timed out after ${timeout.inSeconds}s');
    },
  );

  if (exitCode != 0) {
    throw Exception(
      'mdfind failed (exit $exitCode): ${stderr.toString().trim()}',
    );
  }

  return stdout
      .toString()
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

/// Runs `mdls` on a single file and returns an attribute → value map.
///
/// When [attributes] is provided, only those attributes are queried
/// (using `-name attr` flags), which is faster than fetching all metadata.
Future<Map<String, String>> runMdls(
  String filePath, {
  List<String>? attributes,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final args = <String>[];
  if (attributes != null) {
    for (final attr in attributes) {
      args.addAll(['-name', attr]);
    }
  }
  args.add(filePath);

  final process = await Process.start('mdls', args);

  final stdout = StringBuffer();
  final stderr = StringBuffer();

  process.stdout.transform(utf8.decoder).listen((d) => stdout.write(d));
  process.stderr.transform(utf8.decoder).listen((d) => stderr.write(d));

  final exitCode = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      process.kill();
      throw Exception('mdls timed out after ${timeout.inSeconds}s');
    },
  );

  if (exitCode != 0) {
    throw Exception(
      'mdls failed (exit $exitCode): ${stderr.toString().trim()}',
    );
  }

  return parseMdlsOutput(stdout.toString());
}

/// Runs `mdls` on multiple files at once and returns a list of
/// attribute maps, one per file (in the same order as [filePaths]).
///
/// `mdls` natively accepts multiple paths and separates output with
/// blank lines between files.
Future<List<Map<String, String>>> runMdlsBatch(
  List<String> filePaths, {
  List<String>? attributes,
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (filePaths.isEmpty) return [];

  final args = <String>[];
  if (attributes != null) {
    for (final attr in attributes) {
      args.addAll(['-name', attr]);
    }
  }
  args.addAll(filePaths);

  final process = await Process.start('mdls', args);

  final stdout = StringBuffer();
  final stderr = StringBuffer();

  process.stdout.transform(utf8.decoder).listen((d) => stdout.write(d));
  process.stderr.transform(utf8.decoder).listen((d) => stderr.write(d));

  final exitCode = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      process.kill();
      throw Exception('mdls batch timed out after ${timeout.inSeconds}s');
    },
  );

  if (exitCode != 0) {
    throw Exception(
      'mdls batch failed (exit $exitCode): ${stderr.toString().trim()}',
    );
  }

  return parseMdlsBatchOutput(stdout.toString(), filePaths.length);
}

/// Builds a Spotlight query string for searching .emlx email files.
///
/// All conditions are ANDed together. The content type filter for emlx
/// is always included.
String buildMdfindQuery({
  String? titleContains,
  String? authorContains,
  String? textContains,
  DateTime? dateAfter,
  DateTime? dateBefore,
}) {
  final conditions = <String>[
    'kMDItemContentType == "$emlxContentType"',
  ];

  if (titleContains != null && titleContains.isNotEmpty) {
    conditions.add(
      'kMDItemTitle == "*${_escapeSpotlight(titleContains)}*"cd',
    );
  }

  if (authorContains != null && authorContains.isNotEmpty) {
    conditions.add(
      'kMDItemAuthors == "*${_escapeSpotlight(authorContains)}*"cd',
    );
  }

  if (textContains != null && textContains.isNotEmpty) {
    conditions.add(
      'kMDItemTextContent == "*${_escapeSpotlight(textContains)}*"cd',
    );
  }

  if (dateAfter != null) {
    conditions.add(
      'kMDItemContentCreationDate >= \$time.iso(${dateAfter.toUtc().toIso8601String()})',
    );
  }

  if (dateBefore != null) {
    conditions.add(
      'kMDItemContentCreationDate <= \$time.iso(${dateBefore.toUtc().toIso8601String()})',
    );
  }

  return conditions.join(' && ');
}

/// High-level function to find email .emlx files matching search criteria.
///
/// Combines [buildMdfindQuery] + [runMdfind] with directory scoping.
/// Returns a list of absolute file paths to matching .emlx files.
Future<List<String>> mdfindEmails({
  String? keywords,
  String? sender,
  String? subject,
  DateTime? dateStart,
  DateTime? dateEnd,
  String? scopeDirectory,
}) async {
  // For keyword search, use textContains for broad matching
  final query = buildMdfindQuery(
    titleContains: subject,
    authorContains: sender,
    textContains: keywords,
    dateAfter: dateStart,
    dateBefore: dateEnd,
  );

  return runMdfind(
    query,
    directory: scopeDirectory ?? defaultMailDirectory,
  );
}

/// Resolves Apple Mail account names to their filesystem directories.
///
/// Scans `~/Library/Mail/V*/` for account subdirectories and reads
/// each account's `Info.plist` to map display names to paths.
/// Returns `{accountName: absolutePath}`.
Future<Map<String, String>> resolveAccountPaths() async {
  final homeDir = Platform.environment['HOME'] ?? '/tmp';
  final mailBaseDir = Directory('$homeDir/Library/Mail');

  if (!await mailBaseDir.exists()) {
    return {};
  }

  final result = <String, String>{};

  // Find V* version directories (e.g. V10)
  await for (final versionDir in mailBaseDir.list()) {
    if (versionDir is! Directory) continue;
    final versionName = versionDir.path.split('/').last;
    if (!versionName.startsWith('V')) continue;

    // Each subdirectory is an account
    await for (final accountDir in versionDir.list()) {
      if (accountDir is! Directory) continue;
      final accountDirName = accountDir.path.split('/').last;

      // Skip non-account directories
      if (accountDirName.startsWith('.') ||
          accountDirName == 'Mailboxes') {
        continue;
      }

      // Try to read account name from Info.plist or AccountInfo.plist
      final accountName = await _readAccountName(accountDir.path);
      if (accountName != null) {
        result[accountName] = accountDir.path;
      } else {
        // Fall back to directory name as account identifier
        result[accountDirName] = accountDir.path;
      }
    }
  }

  return result;
}

/// Finds the absolute directory path for a given mailbox within an account.
///
/// Mailboxes are stored as `<name>.mbox/` directories. Handles INBOX
/// variants (INBOX vs Inbox) and nested mailbox paths.
Future<String?> findMailboxDirectory({
  required String accountPath,
  required String mailbox,
}) async {
  // Try exact match first
  final exactPath = '$accountPath/$mailbox.mbox';
  if (await Directory(exactPath).exists()) return exactPath;

  // Try INBOX variants
  if (mailbox.toUpperCase() == 'INBOX') {
    for (final variant in ['INBOX', 'Inbox', 'inbox']) {
      final variantPath = '$accountPath/$variant.mbox';
      if (await Directory(variantPath).exists()) return variantPath;
    }
  }

  // Try case-insensitive scan
  final accountDir = Directory(accountPath);
  if (!await accountDir.exists()) return null;

  final lowerMailbox = mailbox.toLowerCase();
  await for (final entry in accountDir.list()) {
    if (entry is! Directory) continue;
    final dirName = entry.path.split('/').last;
    if (dirName.toLowerCase() == '$lowerMailbox.mbox') {
      return entry.path;
    }
  }

  return null;
}

// ──────────────────────── Parsing helpers ────────────────────────

/// Parses the key-value output from a single `mdls` invocation.
///
/// mdls output format:
/// ```
/// kMDItemTitle = "Subject Line"
/// kMDItemAuthors = ("sender@example.com")
/// kMDItemContentCreationDate = 2024-01-15 10:30:00 +0000
/// ```
Map<String, String> parseMdlsOutput(String output) {
  final result = <String, String>{};

  for (final line in output.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    final eqIndex = trimmed.indexOf('=');
    if (eqIndex < 0) continue;

    final key = trimmed.substring(0, eqIndex).trim();
    var value = trimmed.substring(eqIndex + 1).trim();

    // Skip null values
    if (value == '(null)') continue;

    // Strip quotes from string values
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }

    // Extract first element from array values like ("value")
    if (value.startsWith('(') && !value.startsWith('(null)')) {
      final inner = value.substring(1, value.length - 1).trim();
      if (inner.startsWith('"') && inner.endsWith('"')) {
        value = inner.substring(1, inner.length - 1);
      } else if (inner.isNotEmpty) {
        value = inner;
      }
    }

    result[key] = value;
  }

  return result;
}

/// Parses batch mdls output (multiple files) into a list of attribute maps.
///
/// When mdls processes multiple files, it outputs each file's attributes
/// separated by a blank line or by the file path header.
List<Map<String, String>> parseMdlsBatchOutput(
    String output, int expectedCount) {
  final results = <Map<String, String>>[];
  final currentBlock = StringBuffer();

  for (final line in output.split('\n')) {
    // mdls separates files with the path line (no = sign, starts with /)
    if (line.trim().isEmpty && currentBlock.isNotEmpty) {
      results.add(parseMdlsOutput(currentBlock.toString()));
      currentBlock.clear();
      continue;
    }

    // Skip file path separator lines
    if (line.trim().startsWith('/') && !line.contains('=')) {
      if (currentBlock.isNotEmpty) {
        results.add(parseMdlsOutput(currentBlock.toString()));
        currentBlock.clear();
      }
      continue;
    }

    currentBlock.writeln(line);
  }

  // Don't forget the last block
  if (currentBlock.isNotEmpty) {
    final parsed = parseMdlsOutput(currentBlock.toString());
    if (parsed.isNotEmpty) {
      results.add(parsed);
    }
  }

  return results;
}

// ──────────────────────── Private helpers ────────────────────────

/// Expands `~` to the user's home directory.
String _expandHome(String path) {
  if (path.startsWith('~/') || path == '~') {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return path.replaceFirst('~', home);
  }
  return path;
}

/// Escapes special characters for Spotlight query strings.
///
/// Spotlight queries use `*` as wildcard and `"` for string delimiters,
/// so we need to escape embedded quotes and backslashes.
String _escapeSpotlight(String value) {
  return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}

/// Reads the account display name from an account directory's plist files.
Future<String?> _readAccountName(String accountPath) async {
  // Try common plist file names
  for (final plistName in ['Info.plist', 'AccountInfo.plist']) {
    final plistFile = File('$accountPath/$plistName');
    if (await plistFile.exists()) {
      try {
        final content = await plistFile.readAsString();
        // Simple XML plist parsing — look for AccountName or DisplayName key
        final nameMatch = RegExp(
          r'<key>(?:AccountName|DisplayName)</key>\s*<string>([^<]+)</string>',
        ).firstMatch(content);
        if (nameMatch != null) {
          return nameMatch.group(1);
        }
      } catch (_) {
        // Fall through to next plist or return null
      }
    }
  }
  return null;
}
