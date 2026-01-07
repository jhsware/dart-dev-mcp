import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Test that MCP servers can start without errors.
/// 
/// These tests start each server, wait for the startup message,
/// then terminate the process cleanly.
void main() {
  /// Starts an MCP server and verifies it outputs the expected startup message.
  /// Returns after the server starts successfully or fails with an error.
  Future<void> testServerStartup(
    String serverName,
    String scriptPath,
    List<String> args,
    String expectedOutput,
  ) async {
    final process = await Process.start(
      'dart',
      ['run', scriptPath, ...args],
      workingDirectory: Directory.current.path,
    );

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    var startupDetected = false;

    // Collect stderr (where startup messages go)
    final stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen((data) {
      stderrBuffer.write(data);
      if (data.contains(expectedOutput)) {
        startupDetected = true;
      }
    });

    // Collect stdout
    final stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .listen((data) {
      stdoutBuffer.write(data);
    });

    // Wait for startup or timeout
    final startTime = DateTime.now();
    const timeout = Duration(seconds: 10);
    
    while (!startupDetected) {
      await Future.delayed(Duration(milliseconds: 100));
      
      if (DateTime.now().difference(startTime) > timeout) {
        // Kill process before failing
        process.kill();
        await stderrSubscription.cancel();
        await stdoutSubscription.cancel();
        
        fail(
          '$serverName failed to start within ${timeout.inSeconds} seconds.\n'
          'Expected output containing: "$expectedOutput"\n'
          'Stderr: ${stderrBuffer.toString()}\n'
          'Stdout: ${stdoutBuffer.toString()}',
        );
      }
    }

    // Server started successfully, terminate it
    process.kill(ProcessSignal.sigterm);
    
    // Wait for process to exit
    final exitCode = await process.exitCode.timeout(
      Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );

    await stderrSubscription.cancel();
    await stdoutSubscription.cancel();

    // Verify startup message was received
    expect(
      stderrBuffer.toString(),
      contains(expectedOutput),
      reason: '$serverName should output "$expectedOutput" on startup',
    );
  }

  group('MCP Server Startup Tests', () {
    test('file_edit_mcp.dart starts successfully', () async {
      await testServerStartup(
        'File Edit MCP',
        'bin/file_edit_mcp.dart',
        ['./lib', './bin', './test'],
        'File Edit MCP Server running on stdio',
      );
    });

    test('convert_to_md_mcp.dart starts successfully', () async {
      await testServerStartup(
        'Convert-to-MD MCP',
        'bin/convert_to_md_mcp.dart',
        [],
        'Convert-to-MD MCP Server running on stdio',
      );
    });

    test('fetch_mcp.dart starts successfully', () async {
      await testServerStartup(
        'Fetch MCP',
        'bin/fetch_mcp.dart',
        [],
        'Fetch MCP Server running on stdio',
      );
    });

    test('dart_runner_mcp.dart starts successfully', () async {
      await testServerStartup(
        'Dart Runner MCP',
        'bin/dart_runner_mcp.dart',
        ['.'],
        'Dart Runner MCP Server running on stdio',
      );
    });

    test('flutter_runner_mcp.dart starts successfully', () async {
      await testServerStartup(
        'Flutter Runner MCP',
        'bin/flutter_runner_mcp.dart',
        ['.'],
        'Flutter Runner MCP Server running on stdio',
      );
    });

    test('git_mcp.dart starts successfully', () async {
      await testServerStartup(
        'Git MCP',
        'bin/git_mcp.dart',
        ['.'],
        'Git MCP Server running on stdio',
      );
    });
  });

  group('MCP Server Argument Handling', () {
    test('file_edit_mcp.dart shows error without arguments', () async {
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

    test('file_edit_mcp.dart shows allowed paths on startup', () async {
      final process = await Process.start(
        'dart',
        ['run', 'bin/file_edit_mcp.dart', './lib', './bin'],
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

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Allowed paths:'));
      expect(stderr, contains('lib'));
      expect(stderr, contains('bin'));
    });

    test('dart_runner_mcp.dart shows project path on startup', () async {
      final process = await Process.start(
        'dart',
        ['run', 'bin/dart_runner_mcp.dart', '.'],
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

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
    });

    test('git_mcp.dart shows git status on startup', () async {
      final process = await Process.start(
        'dart',
        ['run', 'bin/git_mcp.dart', '.'],
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

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Is git repository:'));
    });

    test('fetch_mcp.dart shows user agent on startup', () async {
      final process = await Process.start(
        'dart',
        ['run', 'bin/fetch_mcp.dart'],
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

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('User Agent:'));
      expect(stderr, contains('Ignore robots.txt:'));
    });

    test('fetch_mcp.dart accepts --ignore-robots-txt flag', () async {
      final process = await Process.start(
        'dart',
        ['run', 'bin/fetch_mcp.dart', '--ignore-robots-txt'],
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

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Ignore robots.txt: true'));
    });
  });
}
