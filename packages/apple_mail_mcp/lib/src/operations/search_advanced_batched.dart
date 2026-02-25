// Batched handler for get-email-thread operation.
//
// Uses mdfind with kMDItemTitle for fast subject-based thread matching
// via the Spotlight index, replacing the slow AppleScript batch approach.

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import '../batch_helpers.dart';
import '../constants.dart';
import '../mdfind_helpers.dart';

/// Batch size for metadata fetching.
const _metadataBatchSize = 100;

/// Batched get-email-thread handler.
///
/// Thread/conversation view with Re:/Fwd: prefix stripping.
/// Uses mdfind with kMDItemTitle to find thread messages by subject.
Future<void> runBatchedGetEmailThread({
  required Map<String, dynamic> args,
  required ProcessSession session,
  required RequestHandlerExtra extra,
}) async {
  final account = args['account'] as String;
  final subjectKeyword = args['subject_keyword'] as String;
  final mailbox = args['mailbox'] as String? ?? 'INBOX';
  final maxMessages = args['max_messages'] as int? ?? 50;

  // Strip thread prefixes for matching (same logic as sync version)
  var cleanedKeyword = subjectKeyword;
  for (final prefix in threadPrefixes) {
    cleanedKeyword = cleanedKeyword.replaceAll(prefix, '').trim();
  }

  // Write header chunk
  session.chunks.add(
    'EMAIL THREAD VIEW\n\n'
    'Thread topic: $cleanedKeyword\n'
    'Account: $account\n\n',
  );

  // Build mdfind query — search by subject keyword
  await extra.sendProgress(0, message: 'Searching via Spotlight...');

  final escaped = _escapeSpotlight(cleanedKeyword);
  final conditions = <String>[
    'kMDItemContentType == "$emlxContentType"',
    'kMDItemTitle == "*$escaped*"cd',
  ];

  // Resolve scope directory
  final accountPaths = await resolveAccountPaths();
  String? scopeDir;

  for (final entry in accountPaths.entries) {
    if (entry.key.toLowerCase().contains(account.toLowerCase()) ||
        account.toLowerCase().contains(entry.key.toLowerCase())) {
      if (mailbox == 'All') {
        scopeDir = entry.value;
      } else {
        scopeDir = await findMailboxDirectory(
              accountPath: entry.value,
              mailbox: mailbox,
            ) ??
            entry.value;
      }
      break;
    }
  }

  scopeDir ??= defaultMailDirectory;

  final query = conditions.join(' && ');

  List<String> files;
  try {
    files = await runMdfind(query, directory: scopeDir);
  } catch (e) {
    session.chunks.add('Error searching: $e\n');
    session.isComplete = true;
    await extra.sendProgress(1, message: 'get-email-thread completed');
    return;
  }

  if (files.isEmpty) {
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
      message: 'Found ${files.length} messages, fetching metadata...');

  // Fetch metadata in batches, apply Dart-side thread subject filtering
  final batches = batchList(files, _metadataBatchSize);
  var matchedCount = 0;
  var scanned = 0;

  for (var i = 0; i < batches.length; i++) {
    if (session.isComplete) return; // cancelled
    if (matchedCount >= maxMessages) break;

    final batch = batches[i];

    try {
      final metadataList = await fetchEmailMetadata(batch);

      final batchOutput = StringBuffer();
      for (final meta in metadataList) {
        // Dart-side: strip thread prefixes from subject and verify match
        var subject = meta['subject'] ?? '';
        var cleanSubject = subject;
        for (final prefix in threadPrefixes) {
          cleanSubject = cleanSubject.replaceAll(prefix, '').trim();
        }

        if (!cleanSubject.toLowerCase().contains(
              cleanedKeyword.toLowerCase(),
            )) {
          continue;
        }

        matchedCount++;
        if (matchedCount <= maxMessages) {
          final readIndicator = meta['read_status'] == 'read' ? '✓' : '✉';
          batchOutput.writeln('$readIndicator $subject');
          batchOutput.writeln('   From: ${meta['sender']}');
          batchOutput.writeln('   Date: ${meta['date']}');
          batchOutput.writeln('   ID: ${meta['message_id']}');
          batchOutput.writeln();
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
        message: 'Processed $scanned of ${files.length} messages, '
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

// ─────────────────────── Helpers ───────────────────────

/// Escapes special characters for Spotlight query strings.
String _escapeSpotlight(String value) {
  return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}
