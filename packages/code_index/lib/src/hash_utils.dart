import 'dart:io';

import 'package:crypto/crypto.dart';

/// Compute the SHA-256 hash of a file's contents as a lowercase hex string.
String computeFileHash(File file) {
  final bytes = file.readAsBytesSync();
  return sha256.convert(bytes).toString();
}

/// mtime+size short-circuit for change detection (design §4.2).
///
/// Returns true when both the stored [storedMtimeIso] and [storedSize] match
/// the current [stat], meaning the file can be treated as unchanged and
/// hashing can be skipped. Any missing stored value forces a re-hash
/// (returns false).
bool isUnchanged({
  required String? storedMtimeIso,
  required int? storedSize,
  required FileStat stat,
}) {
  if (storedMtimeIso == null || storedSize == null) {
    return false;
  }
  if (storedSize != stat.size) {
    return false;
  }
  final storedMtime = DateTime.tryParse(storedMtimeIso);
  if (storedMtime == null) {
    return false;
  }
  return storedMtime.toUtc() == stat.modified.toUtc();
}
