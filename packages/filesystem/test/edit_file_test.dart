import 'dart:io';

import 'package:filesystem_mcp/src/write_operations.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

/// Extract the text content from a CallToolResult.
String resultText(CallToolResult result) {
  final content = result.content.first;
  if (content is TextContent) {
    return content.text;
  }
  throw StateError('Expected TextContent, got ${content.runtimeType}');
}

void main() {
  late Directory tempDir;
  late Directory libDir;
  late FileWriteOperations writeOps;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('edit_file_test_');
    libDir = Directory('${tempDir.path}/lib');
    await libDir.create();

    writeOps = FileWriteOperations(
      workingDir: tempDir,
      allowedPaths: [libDir.path],
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('editFile insert mode', () {
    test('content with trailing newline does NOT add a blank line', () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('line1\nline2\nline3\n');

      await writeOps.editFile('lib/foo.dart', 'newLine\n', 2, null);

      expect(await file.readAsString(), 'line1\nnewLine\nline2\nline3\n');
    });

    test('content without trailing newline still works', () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('line1\nline2\nline3\n');

      await writeOps.editFile('lib/foo.dart', 'newLine', 2, null);

      expect(await file.readAsString(), 'line1\nnewLine\nline2\nline3\n');
    });

    test('preserves intentional blank lines inside content', () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('line1\nline2\nline3\n');

      await writeOps.editFile('lib/foo.dart', 'a\n\nb\n', 2, null);

      expect(await file.readAsString(), 'line1\na\n\nb\nline2\nline3\n');
    });
  });

  group('editFile insert_at parameter', () {
    test('inserts at the given line (regression: was silently ignored '
        'and overwrote the entire file)', () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('line1\nline2\nline3\n');

      final result = await writeOps.editFile(
          'lib/foo.dart', 'newLine\n', null, null,
          insertAt: 2);

      expect(resultText(result), contains('Inserted'));
      expect(await file.readAsString(), 'line1\nnewLine\nline2\nline3\n');
    });

    test('inserting after the last line appends', () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('line1\nline2\n');

      await writeOps.editFile('lib/foo.dart', 'line3\n', null, null,
          insertAt: 3);

      expect(await file.readAsString(), 'line1\nline2\nline3\n');
    });

    test('combined with startLine is rejected and file is untouched',
        () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('line1\nline2\n');

      final result = await writeOps.editFile(
          'lib/foo.dart', 'x\n', 1, null,
          insertAt: 2);

      expect(resultText(result),
          contains('insert_at cannot be combined with startLine/endLine'));
      expect(await file.readAsString(), 'line1\nline2\n');
    });

    test('combined with endLine is rejected and file is untouched', () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('line1\nline2\n');

      final result = await writeOps.editFile(
          'lib/foo.dart', 'x\n', null, 2,
          insertAt: 2);

      expect(resultText(result),
          contains('insert_at cannot be combined with startLine/endLine'));
      expect(await file.readAsString(), 'line1\nline2\n');
    });

    test('insert_at < 1 is rejected and file is untouched', () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('line1\nline2\n');

      final result = await writeOps.editFile(
          'lib/foo.dart', 'x\n', null, null,
          insertAt: 0);

      expect(resultText(result), contains('insert_at must be >= 1'));
      expect(await file.readAsString(), 'line1\nline2\n');
    });
  });
  group('editFile replace mode', () {
    test('content with trailing newline does NOT add a blank line', () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('line1\nline2\nline3\nline4\n');

      await writeOps.editFile('lib/foo.dart', 'X\nY\n', 2, 3);

      expect(await file.readAsString(), 'line1\nX\nY\nline4\n');
    });

    test('content without trailing newline matches', () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('line1\nline2\nline3\nline4\n');

      await writeOps.editFile('lib/foo.dart', 'X\nY', 2, 3);

      expect(await file.readAsString(), 'line1\nX\nY\nline4\n');
    });
  });

  group('editFile overwrite mode', () {
    test('without overwrite:true is rejected and file is untouched',
        () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('old\n');

      final result =
          await writeOps.editFile('lib/foo.dart', 'new\n', null, null);

      expect(resultText(result), contains('Pass overwrite:true'));
      expect(await file.readAsString(), 'old\n');
    });

    test('with overwrite:true replaces the file and reports the delta',
        () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('a\nb\nc\n');

      final result = await writeOps.editFile(
          'lib/foo.dart', 'new\n', null, null,
          overwrite: true);

      expect(resultText(result),
          contains('Overwrote entire file (3 lines → 1 lines)'));
      expect(await file.readAsString(), 'new\n');
    });
  });

  group('extractLines', () {
    test('extracting range reaching EOF with trailing newline', () async {
      final src = File('${libDir.path}/src.dart');
      await src.writeAsString('a\nb\nc\n');

      await writeOps.extractLines(
          'lib/src.dart', 'lib/dest.dart', 1, 99, null, false);

      final dest = File('${libDir.path}/dest.dart');
      expect(await dest.readAsString(), 'a\nb\nc\n');
    });

    test('appending into existing dest with trailing-newline source',
        () async {
      final src = File('${libDir.path}/src.dart');
      await src.writeAsString('a\nb\n');
      final dest = File('${libDir.path}/dest.dart');
      await dest.writeAsString('existing\n');

      await writeOps.extractLines(
          'lib/src.dart', 'lib/dest.dart', 1, 2, null, false);

      expect(await dest.readAsString(), 'existing\na\nb\n');
    });

    test('preserves source trailing newline when removeFromSource=true',
        () async {
      final src = File('${libDir.path}/src.dart');
      await src.writeAsString('a\nb\nc\nd\n');

      await writeOps.extractLines(
          'lib/src.dart', 'lib/dest.dart', 2, 3, null, true);

      expect(await src.readAsString(), 'a\nd\n');
      final dest = File('${libDir.path}/dest.dart');
      expect(await dest.readAsString(), 'b\nc\n');
    });
  });
}
