// Parser for Apple Mail .emlx files.
//
// An .emlx file contains:
//   1. First line: byte count of the email data
//   2. RFC 2822 email headers + body
//   3. Apple plist XML with flags metadata (read status, etc.)
//
// The file path encodes account and mailbox information:
//   ~/Library/Mail/V10/<account-uuid>/<mailbox>.mbox/Messages/<id>.emlx

import 'dart:io';

/// Information extracted from an .emlx file path.
class EmlxPathInfo {
  /// The account directory name (UUID or identifier).
  final String accountDir;

  /// The mailbox name (without the `.mbox` suffix).
  final String mailbox;

  /// The numeric message file ID (from the filename).
  final String fileId;

  const EmlxPathInfo({
    required this.accountDir,
    required this.mailbox,
    required this.fileId,
  });

  @override
  String toString() =>
      'EmlxPathInfo(account: $accountDir, mailbox: $mailbox, id: $fileId)';
}

/// Parsed content from an .emlx file.
class EmlxContent {
  /// RFC 2822 Message-ID header value.
  final String? messageId;

  /// Subject header.
  final String? subject;

  /// From header (sender).
  final String? sender;

  /// Date header value as raw string.
  final String? dateStr;

  /// Whether the message has been read (from Apple plist flags).
  final bool isRead;

  /// Whether the message has attachments (from Apple plist flags).
  final bool hasAttachments;

  /// Body text preview (first N characters of the body).
  final String? bodyPreview;

  const EmlxContent({
    this.messageId,
    this.subject,
    this.sender,
    this.dateStr,
    this.isRead = false,
    this.hasAttachments = false,
    this.bodyPreview,
  });
}

/// Extracts account directory and mailbox name from an .emlx file path.
///
/// Example path:
/// `/Users/x/Library/Mail/V10/ABC-UUID/INBOX.mbox/Messages/12345.emlx`
/// → `EmlxPathInfo(accountDir: 'ABC-UUID', mailbox: 'INBOX', fileId: '12345')`
///
/// Returns `null` if the path doesn't match the expected structure.
EmlxPathInfo? parseEmlxPath(String filePath) {
  // Normalize to forward slashes
  final path = filePath.replaceAll('\\', '/');

  // Expected pattern: .../V<n>/<account-dir>/<mailbox>.mbox/Messages/<id>.emlx
  // We search for the .mbox segment and work relative to it.
  final mboxIndex = path.indexOf('.mbox/');
  if (mboxIndex < 0) return null;

  // Extract everything before .mbox
  final beforeMbox = path.substring(0, mboxIndex);
  final segments = beforeMbox.split('/');
  if (segments.length < 2) return null;

  final mailbox = segments.last;
  final accountDir = segments[segments.length - 2];

  // Extract file ID from the filename
  final fileName = path.split('/').last;
  final fileId = fileName.replaceAll(RegExp(r'\.emlx$'), '');

  return EmlxPathInfo(
    accountDir: accountDir,
    mailbox: mailbox,
    fileId: fileId,
  );
}

/// Reads an .emlx file and extracts the RFC 2822 Message-ID header.
///
/// Reads only the header portion (up to the first blank line) for efficiency.
/// Returns `null` if the file doesn't exist or the header isn't found.
Future<String?> parseEmlxMessageId(String filePath) async {
  final headers = await _readEmlxHeaders(filePath);
  if (headers == null) return null;

  return _extractHeader(headers, 'Message-ID') ??
      _extractHeader(headers, 'Message-Id') ??
      _extractHeader(headers, 'message-id');
}

/// Reads an .emlx file and extracts key email metadata.
///
/// Parses both the RFC 2822 headers and the trailing Apple plist
/// for a complete picture of the message.
Future<EmlxContent?> parseEmlxContent(
  String filePath, {
  int bodyPreviewLength = 200,
}) async {
  final file = File(filePath);
  if (!await file.exists()) return null;

  try {
    final content = await file.readAsString();
    return parseEmlxContentFromString(
      content,
      bodyPreviewLength: bodyPreviewLength,
    );
  } catch (_) {
    return null;
  }
}

/// Parses .emlx content from an already-read string.
///
/// Useful for testing without file I/O.
EmlxContent? parseEmlxContentFromString(
  String content, {
  int bodyPreviewLength = 200,
}) {
  if (content.isEmpty) return null;

  // First line is the byte count
  final firstNewline = content.indexOf('\n');
  if (firstNewline < 0) return null;

  final byteCountStr = content.substring(0, firstNewline).trim();
  final byteCount = int.tryParse(byteCountStr);
  if (byteCount == null) return null;

  // Email data starts after the first newline
  final emailStart = firstNewline + 1;
  final emailEnd = emailStart + byteCount;
  final emailData = content.substring(
    emailStart,
    emailEnd.clamp(emailStart, content.length),
  );

  // Split headers from body at the first blank line
  final headerEndIndex = emailData.indexOf('\r\n\r\n');
  final headerEndAlt = emailData.indexOf('\n\n');
  final headerEnd = headerEndIndex >= 0
      ? headerEndIndex
      : (headerEndAlt >= 0 ? headerEndAlt : emailData.length);

  final headerSection = emailData.substring(0, headerEnd);
  final bodyStart = headerEnd < emailData.length
      ? headerEnd + (headerEndIndex >= 0 ? 4 : 2)
      : emailData.length;
  final body = bodyStart < emailData.length
      ? emailData.substring(bodyStart)
      : '';

  // Parse headers
  final messageId = _extractHeader(headerSection, 'Message-ID') ??
      _extractHeader(headerSection, 'Message-Id');
  final subject = _extractHeader(headerSection, 'Subject');
  final sender = _extractHeader(headerSection, 'From');
  final dateStr = _extractHeader(headerSection, 'Date');

  // Parse Apple plist flags (after the email data)
  final plistSection =
      emailEnd < content.length ? content.substring(emailEnd) : '';
  final flags = _parsePlistFlags(plistSection);
  final isRead = (flags & 1) != 0; // Bit 0 = read
  final hasAttachments = (flags & 4) != 0; // Bit 2 = has attachments

  // Body preview
  final preview = body.isNotEmpty
      ? _cleanBodyPreview(body, bodyPreviewLength)
      : null;

  return EmlxContent(
    messageId: messageId,
    subject: subject,
    sender: sender,
    dateStr: dateStr,
    isRead: isRead,
    hasAttachments: hasAttachments,
    bodyPreview: preview,
  );
}

/// Reads an .emlx file and extracts just the read status from plist flags.
///
/// Bit 0 of the flags integer indicates read (1) or unread (0).
Future<bool> parseEmlxReadStatus(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) return false;

  try {
    final content = await file.readAsString();

    // Find the byte count on the first line
    final firstNewline = content.indexOf('\n');
    if (firstNewline < 0) return false;

    final byteCountStr = content.substring(0, firstNewline).trim();
    final byteCount = int.tryParse(byteCountStr);
    if (byteCount == null) return false;

    // Plist section starts after byte count line + email data
    final emailStart = firstNewline + 1;
    final emailEnd = emailStart + byteCount;
    if (emailEnd >= content.length) return false;

    final plistSection = content.substring(emailEnd);
    final flags = _parsePlistFlags(plistSection);
    return (flags & 1) != 0;
  } catch (_) {
    return false;
  }
}

// ──────────────────────── Private helpers ────────────────────────

/// Reads just the header section of an .emlx file (up to the first blank line).
Future<String?> _readEmlxHeaders(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) return null;

  try {
    // Read the file — .emlx files are typically small enough to read fully
    final content = await file.readAsString();

    // Skip the byte count line
    final firstNewline = content.indexOf('\n');
    if (firstNewline < 0) return null;

    final emailStart = firstNewline + 1;

    // Find end of headers (blank line)
    final headerEnd1 = content.indexOf('\r\n\r\n', emailStart);
    final headerEnd2 = content.indexOf('\n\n', emailStart);
    final headerEnd = headerEnd1 >= 0
        ? headerEnd1
        : (headerEnd2 >= 0 ? headerEnd2 : content.length);

    return content.substring(emailStart, headerEnd);
  } catch (_) {
    return null;
  }
}

/// Extracts a specific header value from an RFC 2822 header block.
///
/// Handles multi-line header values (continuation lines starting with
/// whitespace).
String? _extractHeader(String headers, String headerName) {
  final pattern = RegExp(
    '^${RegExp.escape(headerName)}:\\s*(.*)',
    multiLine: true,
    caseSensitive: false,
  );

  final match = pattern.firstMatch(headers);
  if (match == null) return null;

  var value = match.group(1)?.trim() ?? '';

  // Handle continuation lines (RFC 2822 folding)
  final startIndex = match.end;
  final remaining = headers.substring(startIndex);
  final remainingLines = remaining.split('\n');
  for (final line in remainingLines) {
    // Skip empty lines at the boundary between match and continuation
    if (line.isEmpty) continue;
    if (line.startsWith(' ') || line.startsWith('\t')) {
      value += ' ${line.trim()}';
    } else {
      break;
    }
  }

  // Strip angle brackets from Message-ID
  if (headerName.toLowerCase() == 'message-id') {
    value = value.replaceAll(RegExp(r'^<|>$'), '');
  }

  return value.isEmpty ? null : value;
}

/// Parses the Apple plist XML section to extract the `flags` integer.
///
/// The plist is a simple XML structure like:
/// ```xml
/// <?xml version="1.0" encoding="UTF-8"?>
/// <!DOCTYPE plist ...>
/// <plist version="1.0">
/// <dict>
///   <key>flags</key>
///   <integer>8590195713</integer>
///   ...
/// </dict>
/// </plist>
/// ```
int _parsePlistFlags(String plistSection) {
  final flagsMatch = RegExp(
    r'<key>flags</key>\s*<integer>(\d+)</integer>',
  ).firstMatch(plistSection);

  if (flagsMatch == null) return 0;

  return int.tryParse(flagsMatch.group(1) ?? '0') ?? 0;
}

/// Cleans up body text for a preview: strips HTML tags, collapses whitespace,
/// and truncates to [maxLength].
String _cleanBodyPreview(String body, int maxLength) {
  // Strip HTML tags if present
  var cleaned = body.replaceAll(RegExp(r'<[^>]+>'), ' ');
  // Collapse whitespace
  cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Truncate
  if (cleaned.length > maxLength) {
    cleaned = '${cleaned.substring(0, maxLength)}...';
  }
  return cleaned;
}
