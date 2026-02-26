// Batch helpers for Apple Mail MCP operations.
//
// Provides utilities for fetching message IDs and metadata in bulk,
// splitting work into batches for progressive processing with
// cancellation support.
//
// Message discovery uses mdfind (Spotlight CLI) for fast index queries.
// Metadata extraction uses mdls and .emlx file parsing.

import 'core.dart';
import 'constants.dart';
import 'emlx_parser.dart';
import 'mdfind_helpers.dart';

/// Splits a list into batches of the given size.
///
/// Example: `batchList([1,2,3,4,5], 2)` → `[[1,2], [3,4], [5]]`
List<List<T>> batchList<T>(List<T> items, int batchSize) {
  final batches = <List<T>>[];
  for (var i = 0; i < items.length; i += batchSize) {
    final end = (i + batchSize < items.length) ? i + batchSize : items.length;
    batches.add(items.sublist(i, end));
  }
  return batches;
}

/// Fetches .emlx file paths from a mailbox, optionally filtered by date.
///
/// Uses mdfind (Spotlight CLI) for fast index-based queries instead of
/// AppleScript enumeration. Returns absolute paths to matching .emlx files.
///
/// When [mailbox] is "All", searches the entire account directory but
/// filters out system folders (Trash, Junk, Sent, Drafts, etc.).
Future<List<String>> fetchEmailFiles({
  required String account,
  required String mailbox,
  int daysBack = 0,
  String? startDate,
  String? endDate,
}) async {
  // Resolve account name → filesystem path
  final accountPaths = await resolveAccountPaths();
  final accountPath = accountPaths[account];
  if (accountPath == null) {
    // Try partial match (account name might differ slightly)
    final matchingKey = accountPaths.keys.firstWhere(
      (k) => k.toLowerCase().contains(account.toLowerCase()) ||
          account.toLowerCase().contains(k.toLowerCase()),
      orElse: () => '',
    );
    if (matchingKey.isEmpty) {
      throw Exception('Account "$account" not found in Mail directory');
    }
    return _fetchEmailFilesFromPath(
      accountPath: accountPaths[matchingKey]!,
      mailbox: mailbox,
      daysBack: daysBack,
      startDate: startDate,
      endDate: endDate,
    );
  }

  return _fetchEmailFilesFromPath(
    accountPath: accountPath,
    mailbox: mailbox,
    daysBack: daysBack,
    startDate: startDate,
    endDate: endDate,
  );
}

/// Internal: fetches .emlx files from a resolved account path.
Future<List<String>> _fetchEmailFilesFromPath({
  required String accountPath,
  required String mailbox,
  int daysBack = 0,
  String? startDate,
  String? endDate,
}) async {
  // Build date filters
  DateTime? dateAfter;
  DateTime? dateBefore;

  if (daysBack > 0) {
    dateAfter = DateTime.now().subtract(Duration(days: daysBack));
  }

  if (startDate != null) {
    dateAfter = DateTime.parse(startDate);
  }

  if (endDate != null) {
    // End of day
    dateBefore = DateTime.parse(endDate).add(const Duration(
      hours: 23,
      minutes: 59,
      seconds: 59,
    ));
  }

  // Determine search scope directory
  String scopeDir;
  if (mailbox == 'All') {
    scopeDir = accountPath;
  } else {
    final mailboxDir = await findMailboxDirectory(
      accountPath: accountPath,
      mailbox: mailbox,
    );
    if (mailboxDir == null) {
      // Mailbox not found (may not exist, or directory listing blocked
      // by macOS privacy restrictions without Full Disk Access).
      return [];
    }
    scopeDir = mailboxDir;
  }

  // Build and run mdfind query
  final query = buildMdfindQuery(
    dateAfter: dateAfter,
    dateBefore: dateBefore,
  );

  final files = await runMdfind(query, directory: scopeDir);

  // For "All" mailbox, filter out system folders
  if (mailbox == 'All') {
    return files.where((path) => !_isSystemFolderPath(path)).toList();
  }

  return files;
}

/// Fetches message IDs from a mailbox, optionally filtered by date.
///
/// Uses mdfind (Spotlight CLI) for fast message discovery, then extracts
/// RFC Message-ID headers from matching .emlx files.
///
/// When [mailbox] is "All", searches all mailboxes except system folders
/// (Trash, Junk, Sent, Drafts, etc.).
Future<List<String>> fetchMessageIds({
  required String account,
  required String mailbox,
  int daysBack = 0,
  String? startDate,
  String? endDate,
}) async {
  final files = await fetchEmailFiles(
    account: account,
    mailbox: mailbox,
    daysBack: daysBack,
    startDate: startDate,
    endDate: endDate,
  );

  // Extract Message-ID from each .emlx file
  final ids = <String>[];
  for (final filePath in files) {
    final messageId = await parseEmlxMessageId(filePath);
    if (messageId != null && messageId.isNotEmpty) {
      ids.add(messageId);
    }
  }

  return ids;
}

/// Fetches email metadata for multiple .emlx files using mdls and parsing.
///
/// Returns a list of maps with keys: subject, sender, date, message_id,
/// read_status, mailbox, account, file_path.
///
/// Uses mdls for fast Spotlight-indexed metadata (subject, sender, date)
/// and .emlx parsing for Message-ID and read status.
Future<List<Map<String, String>>> fetchEmailMetadata(
    List<String> emlxPaths) async {
  if (emlxPaths.isEmpty) return [];

  // Batch mdls queries in groups of 100 to avoid command line limits
  final results = <Map<String, String>>[];
  final batches = batchList(emlxPaths, 100);

  for (final batch in batches) {
    final mdlsResults = await runMdlsBatch(
      batch,
      attributes: [
        'kMDItemTitle',
        'kMDItemAuthors',
        'kMDItemContentCreationDate',
      ],
    );

    for (var i = 0; i < batch.length; i++) {
      final filePath = batch[i];
      final mdls = i < mdlsResults.length ? mdlsResults[i] : <String, String>{};

      // Extract path-based info
      final pathInfo = parseEmlxPath(filePath);

      // Parse .emlx for Message-ID and read status
      final content = await parseEmlxContent(filePath, bodyPreviewLength: 0);

      results.add({
        'file_path': filePath,
        'subject': mdls['kMDItemTitle'] ?? content?.subject ?? '',
        'sender': mdls['kMDItemAuthors'] ?? content?.sender ?? '',
        'date': mdls['kMDItemContentCreationDate'] ?? content?.dateStr ?? '',
        'message_id': content?.messageId ?? '',
        'read_status': (content?.isRead ?? false) ? 'read' : 'unread',
        'mailbox': pathInfo?.mailbox ?? '',
        'account': pathInfo?.accountDir ?? '',
        'has_attachments': (content?.hasAttachments ?? false) ? 'true' : 'false',
      });
    }
  }

  return results;
}

/// Fetches the list of account names from Apple Mail.
///
/// Uses filesystem scanning of ~/Library/Mail/ to discover accounts,
/// reading account plists for display names.
Future<List<String>> fetchAccountNames() async {
  final accountPaths = await resolveAccountPaths();
  return accountPaths.keys.toList();
}

// ──────────────────────── Private helpers ────────────────────────

/// System folder names to skip when searching "All" mailboxes.
/// These are matched against the .mbox directory name in the file path.
final _systemFolderPatterns = [
  ...skipFolders.map((f) => '/$f.mbox/'),
  '/Junk Email.mbox/',
  '/Deleted Items.mbox/',
  '/Sent Items.mbox/',
  '/Sent Messages.mbox/',
];

/// Checks if an .emlx file path is within a system folder that should
/// be skipped when searching "All" mailboxes.
bool _isSystemFolderPath(String path) {
  final lowerPath = path.toLowerCase();
  return _systemFolderPatterns.any(
    (pattern) => lowerPath.contains(pattern.toLowerCase()),
  );
}

/// Builds an AppleScript set literal from a list of message IDs.
///
/// Used by attachment operations that still use AppleScript batch processing.
/// Example: `buildMessageIdSet(['a', 'b'])` → `{"a", "b"}`
String buildMessageIdSet(List<String> ids) {
  final escaped = ids.map((id) {
    return '"${escapeAppleScript(id)}"';
  }).join(', ');
  return '{$escaped}';
}
