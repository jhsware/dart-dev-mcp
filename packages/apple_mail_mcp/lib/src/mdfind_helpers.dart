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
/// each account's plist files to map display names and email addresses
/// to paths. Multiple name variants per account are stored so that
/// AppleScript-discovered names (typically email addresses) can be
/// resolved to filesystem paths.
/// Returns `{nameVariant: absolutePath}`.
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

      // Read all name variants from plists
      final names = await _readAccountNames(accountDir.path);
      if (names.isNotEmpty) {
        for (final name in names) {
          result[name] = accountDir.path;
        }
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

/// Reads account name variants from an account directory's plist files.
///
/// Returns multiple name variants including AccountName, DisplayName,
/// email addresses (from EmailAddresses array, AccountURL, or
/// Username/Hostname keys). This ensures AppleScript-discovered names
/// (typically email addresses) can be matched to filesystem paths.
Future<List<String>> _readAccountNames(String accountPath) async {
  final names = <String>{};

  for (final plistName in ['Info.plist', 'AccountInfo.plist']) {
    final plistFile = File('$accountPath/$plistName');
    if (await plistFile.exists()) {
      try {
        final content = await plistFile.readAsString();

        // 1. AccountName / DisplayName
        final nameMatches = RegExp(
          r'<key>(?:AccountName|DisplayName)</key>\s*<string>([^<]+)</string>',
        ).allMatches(content);
        for (final m in nameMatches) {
          final name = m.group(1)!.trim();
          if (name.isNotEmpty) names.add(name);
        }

        // 2. EmailAddresses array
        final emailArrayMatch = RegExp(
          r'<key>EmailAddresses</key>\s*<array>(.*?)</array>',
          dotAll: true,
        ).firstMatch(content);
        if (emailArrayMatch != null) {
          final strings = RegExp(r'<string>([^<]+)</string>')
              .allMatches(emailArrayMatch.group(1)!)
              .map((m) => m.group(1)!.trim())
              .where((s) => s.isNotEmpty);
          names.addAll(strings);
        }

        // 3. AccountURL — extract username (email) from URL
        //    e.g. imap://user%40example.com@mail.example.com
        final urlMatch = RegExp(
          r'<key>AccountURL</key>\s*<string>([^<]+)</string>',
        ).firstMatch(content);
        if (urlMatch != null) {
          final url = urlMatch.group(1)!;
          // Extract the user info part (before the last @host)
          final schemeStripped = url.replaceFirst(RegExp(r'^[a-z]+://'), '');
          final atIndex = schemeStripped.lastIndexOf('@');
          if (atIndex > 0) {
            final userInfo = Uri.decodeComponent(
              schemeStripped.substring(0, atIndex),
            );
            if (userInfo.isNotEmpty) names.add(userInfo);
          }
        }

        // 4. Username (+ Hostname fallback)
        final usernameMatch = RegExp(
          r'<key>Username</key>\s*<string>([^<]+)</string>',
        ).firstMatch(content);
        if (usernameMatch != null) {
          final username = usernameMatch.group(1)!.trim();
          if (username.contains('@')) {
            names.add(username);
          } else if (username.isNotEmpty) {
            // Try combining with Hostname
            final hostMatch = RegExp(
              r'<key>Hostname</key>\s*<string>([^<]+)</string>',
            ).firstMatch(content);
            if (hostMatch != null) {
              final host = hostMatch.group(1)!.trim();
              if (host.isNotEmpty) {
                names.add('$username@$host');
              }
            }
            names.add(username);
          }
        }
      } catch (_) {
        // Fall through to next plist or return empty
      }
    }
  }

  return names.toList();
}
