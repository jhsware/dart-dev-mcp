import 'dart:io';

import 'package:filesystem_mcp/src/write_operations.dart';
import 'package:test/test.dart';

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
    test('Mode 1 is unchanged', () async {
      final file = File('${libDir.path}/foo.dart');
      await file.writeAsString('old\n');

      await writeOps.editFile('lib/foo.dart', 'new\n', null, null);

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
