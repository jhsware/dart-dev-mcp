import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Test MCP server argument handling and configuration output.
void main() {
  /// Helper to start a server and wait for it to be ready
  Future<(Process, StringBuffer)> startServer(
    String scriptPath,
    List<String> args,
  ) async {
    final process = await Process.start(
      'dart',
      ['run', scriptPath, ...args],
      workingDirectory: Directory.current.path,
    );

    final stderrBuffer = StringBuffer();
    var complete = false;

    process.stderr.transform(utf8.decoder).listen((data) {
      stderrBuffer.write(data);
      if (data.contains('running on stdio')) {
        complete = true;
      }
    });

    // Wait for startup
    final startTime = DateTime.now();
    while (!complete && DateTime.now().difference(startTime).inSeconds < 10) {
      await Future.delayed(Duration(milliseconds: 100));
    }

    return (process, stderrBuffer);
  }

  group('file_edit_mcp.dart arguments', () {
    test('shows error without arguments', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/file_edit_mcp.dart'],
        workingDirectory: Directory.current.path,
      );

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('Usage: file_edit_mcp'),
      );
    });

    test('shows allowed paths on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/file_edit_mcp.dart',
        ['./lib', './bin'],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Allowed paths:'));
      expect(stderr, contains('lib'));
      expect(stderr, contains('bin'));
    });
  });

  group('dart_runner_mcp.dart arguments', () {
    test('shows project path on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/dart_runner_mcp.dart',
        ['.'],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
    });

    test('uses current directory when no path specified', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/dart_runner_mcp.dart',
        [],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
      expect(stderr, contains('dart_dev_mcp'));
    });
  });

  group('flutter_runner_mcp.dart arguments', () {
    test('shows project path on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/flutter_runner_mcp.dart',
        ['.'],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
    });

    test('shows FVM status', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/flutter_runner_mcp.dart',
        ['.'],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Using FVM:'));
    });
  });

  group('git_mcp.dart arguments', () {
    test('shows git status on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/git_mcp.dart',
        ['.'],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Is git repository:'));
    });

    test('shows project path on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/git_mcp.dart',
        ['.'],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
    });
  });

  group('fetch_mcp.dart arguments', () {
    test('shows user agent on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/fetch_mcp.dart',
        [],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('User Agent:'));
      expect(stderr, contains('Ignore robots.txt:'));
    });

    test('accepts --ignore-robots-txt flag', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/fetch_mcp.dart',
        ['--ignore-robots-txt'],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Ignore robots.txt: true'));
    });

    test('defaults to respecting robots.txt', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/fetch_mcp.dart',
        [],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Ignore robots.txt: false'));
    });
  });

  group('convert_to_md_mcp.dart arguments', () {
    test('starts without any arguments', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/convert_to_md_mcp.dart',
        [],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Convert-to-MD MCP Server starting'));
      expect(stderr, contains('running on stdio'));
    });
  });
}
