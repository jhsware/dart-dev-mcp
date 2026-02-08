import 'dart:io';
import 'dart:typed_data';

import 'package:xxh3/xxh3.dart';

/// Compute the XXH3-64 hash of a file's contents as a hex string.
String computeFileHash(File file) {
  final Uint8List bytes = file.readAsBytesSync();
  return xxh3String(bytes);
}
