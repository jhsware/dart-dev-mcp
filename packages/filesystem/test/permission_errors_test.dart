import 'dart:io';

import 'package:filesystem_mcp/src/read_operations.dart';
import 'package:filesystem_mcp/src/write_operations.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';
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
  late Directory testDir;
  late File allowedFile;
  late FileReadOperations readOps;
  late FileWriteOperations writeOps;
  late List<String> allowedPaths;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('filesystem_test_');

    // Create some allowed directories and files
    libDir = Directory('${tempDir.path}/lib');
    await libDir.create();
    testDir = Directory('${tempDir.path}/test');
    await testDir.create();
    allowedFile = File('${tempDir.path}/pubspec.yaml');
    await allowedFile.writeAsString('name: test_project');

    // Create a file inside allowed dir for reading
    await File('${libDir.path}/main.dart').writeAsString('void main() {}');

    // Create a directory outside allowed paths
    final srcDir = Directory('${tempDir.path}/src');
    await srcDir.create();
    await File('${srcDir.path}/secret.dart').writeAsString('secret');

    allowedPaths = [libDir.path, testDir.path, allowedFile.path];

    readOps = FileReadOperations(
      workingDir: tempDir,
      allowedPaths: allowedPaths,
    );
    writeOps = FileWriteOperations(
      workingDir: tempDir,
      allowedPaths: allowedPaths,
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('formatAllowedPathsHint', () {
    test('produces relative paths from absolute allowed paths', () {
      final hint = formatAllowedPathsHint(tempDir, allowedPaths);
      expect(hint, equals('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('handles single allowed path', () {
      final hint = formatAllowedPathsHint(tempDir, [libDir.path]);
      expect(hint, equals('Allowed paths: lib'));
    });
  });

  group('getAllowedRelativePaths', () {
    test('strips workingDir prefix from paths', () {
      final paths = getAllowedRelativePaths(tempDir, allowedPaths);
      expect(paths, equals(['lib', 'test', 'pubspec.yaml']));
    });
  });

  group('FileReadOperations - "Not allowed" errors', () {
    test('readFile includes allowed paths in error', () async {
      final result = await readOps.readFile('src/secret.dart');
      final text = resultText(result);
      expect(text, contains('Not allowed for: src/secret.dart'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('listContent includes allowed paths in error', () async {
      final result = await readOps.listContent('src');
      final text = resultText(result);
      expect(text, contains('Not allowed for: src'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('readFiles includes allowed paths in error', () async {
      final result = await readOps.readFiles(['src/secret.dart']);
      final text = resultText(result);
      expect(text, contains('Not allowed'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('searchText includes allowed paths in error', () async {
      final result = await readOps.searchText('src', 'pattern', null, true);
      final text = resultText(result);
      expect(text, contains('Not allowed for: src'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });
  });

  group('FileWriteOperations - "Not allowed" errors', () {
    test('createDirectory includes allowed paths in error', () async {
      final result = await writeOps.createDirectory('src/new');
      final text = resultText(result);
      expect(text, contains('Not allowed for: src/new'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('createFile includes allowed paths in error', () async {
      final result = await writeOps.createFile('src/new.dart', 'content');
      final text = resultText(result);
      expect(text, contains('Not allowed for: src/new.dart'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('editFile includes allowed paths in error', () async {
      final result = await writeOps.editFile('src/secret.dart', 'new content', null, null);
      final text = resultText(result);
      expect(text, contains('Not allowed for: src/secret.dart'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });
  });

  group('validateRelativePath errors include allowed paths hint', () {
    test('absolute path error includes allowed paths', () async {
      final result = await readOps.readFile('/etc/passwd');
      final text = resultText(result);
      expect(text, contains('No absolute paths allowed'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('hidden file error includes allowed paths', () async {
      final result = await readOps.readFile('.hidden/file');
      final text = resultText(result);
      expect(text, contains('No hidden files or directories allowed'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('parent traversal error includes allowed paths', () async {
      // Note: '..' as a path segment triggers hidden file check first
      // (because '..' starts with '.' and != '.').
      // Use 'foo..bar' to trigger parent traversal check specifically.
      final result = await readOps.readFile('foo..bar');
      final text = resultText(result);
      expect(text, contains('No parent directory traversal allowed'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('write operation absolute path error includes allowed paths', () async {
      final result = await writeOps.createFile('/tmp/evil.dart', 'content');
      final text = resultText(result);
      expect(text, contains('No absolute paths allowed'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('write operation hidden file error includes allowed paths', () async {
      final result = await writeOps.createFile('.hidden/file.dart', 'content');
      final text = resultText(result);
      expect(text, contains('No hidden files or directories allowed'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });

    test('write operation parent traversal error includes allowed paths', () async {
      // Same as above — use embedded '..' to trigger traversal check
      final result = await writeOps.editFile('foo..bar', 'content', null, null);
      final text = resultText(result);
      expect(text, contains('No parent directory traversal allowed'));
      expect(text, contains('Allowed paths: lib, test, pubspec.yaml'));
    });
  });
}