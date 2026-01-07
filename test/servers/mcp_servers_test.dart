import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Pre-compiled kernel files for faster test execution
final Map<String, String> _compiledKernels = {};

/// All server scripts to compile
const _serverScripts = [
  'bin/file_edit_mcp.dart',
  'bin/convert_to_md_mcp.dart',
  'bin/fetch_mcp.dart',
  'bin/dart_runner_mcp.dart',
  'bin/flutter_runner_mcp.dart',
  'bin/git_mcp.dart',
];

/// Compiles a Dart script to kernel format (.dill) for faster execution
Future<String> _compileToKernel(String scriptPath) async {
  if (_compiledKernels.containsKey(scriptPath)) {
    return _compiledKernels[scriptPath]!;
  }

  final dillPath = scriptPath.replaceAll('.dart', '.dill');

  final result = await Process.run(
    'dart',
    ['compile', 'kernel', scriptPath, '-o', dillPath],
    workingDirectory: Directory.current.path,
  );

  if (result.exitCode != 0) {
    throw Exception('Failed to compile $scriptPath: ${result.stderr}');
  }

  _compiledKernels[scriptPath] = dillPath;
  return dillPath;
}

/// Clean up compiled kernel files
Future<void> _cleanupKernels() async {
  for (final dillPath in _compiledKernels.values) {
    try {
      await File(dillPath).delete();
    } catch (_) {}
  }
  _compiledKernels.clear();
}

/// Helper to start a server and wait for it to be ready
Future<(Process, StringBuffer)> _startServer(
  String scriptPath,
  List<String> args,
) async {
  final dillPath = await _compileToKernel(scriptPath);

  final process = await Process.start(
    'dart',
    ['run', dillPath, ...args],
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

  // Drain stdout to prevent blocking
  process.stdout.transform(utf8.decoder).listen((_) {});

  // Wait for startup with short polling interval
  final startTime = DateTime.now();
  while (!complete && DateTime.now().difference(startTime).inSeconds < 5) {
    await Future.delayed(Duration(milliseconds: 20));
  }

  return (process, stderrBuffer);
}

/// Test server startup and verify output contains expected message
Future<void> _testServerStartup(
  String serverName,
  String scriptPath,
  List<String> args,
  String expectedOutput,
) async {
  final (process, stderrBuffer) = await _startServer(scriptPath, args);

  process.kill(ProcessSignal.sigterm);
  await process.exitCode.timeout(
    Duration(seconds: 2),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );

  expect(
    stderrBuffer.toString(),
    contains(expectedOutput),
    reason: '$serverName should output "$expectedOutput"',
  );
}

void main() {
  setUpAll(() async {
    // Pre-compile all servers in parallel (significant speedup)
    await Future.wait(_serverScripts.map(_compileToKernel));
  });

  tearDownAll(() async {
    await _cleanupKernels();
  });

  // ===== STARTUP TESTS =====
  group('MCP Server Startup', () {
    test('file_edit_mcp starts successfully', () async {
      await _testServerStartup(
        'File Edit MCP',
        'bin/file_edit_mcp.dart',
        ['./lib', './bin', './test'],
        'File Edit MCP Server running on stdio',
      );
    });

    test('convert_to_md_mcp starts successfully', () async {
      await _testServerStartup(
        'Convert-to-MD MCP',
        'bin/convert_to_md_mcp.dart',
        [],
        'Convert-to-MD MCP Server running on stdio',
      );
    });

    test('fetch_mcp starts successfully', () async {
      await _testServerStartup(
        'Fetch MCP',
        'bin/fetch_mcp.dart',
        [],
        'Fetch MCP Server running on stdio',
      );
    });

    test('dart_runner_mcp starts successfully', () async {
      await _testServerStartup(
        'Dart Runner MCP',
        'bin/dart_runner_mcp.dart',
        ['.'],
        'Dart Runner MCP Server running on stdio',
      );
    });

    test('flutter_runner_mcp starts successfully', () async {
      await _testServerStartup(
        'Flutter Runner MCP',
        'bin/flutter_runner_mcp.dart',
        ['.'],
        'Flutter Runner MCP Server running on stdio',
      );
    });

    test('git_mcp starts successfully', () async {
      await _testServerStartup(
        'Git MCP',
        'bin/git_mcp.dart',
        ['.'],
        'Git MCP Server running on stdio',
      );
    });
  });

  // ===== ARGUMENT HANDLING TESTS =====
  group('file_edit_mcp arguments', () {
    test('shows error without arguments', () async {
      final dillPath = await _compileToKernel('bin/file_edit_mcp.dart');
      final result = await Process.run(
        'dart',
        ['run', dillPath],
        workingDirectory: Directory.current.path,
      );

      expect(result.exitCode, 1);
      expect(result.stderr, contains('Usage: file_edit_mcp'));
    });

    test('shows allowed paths on startup', () async {
      final (process, stderrBuffer) = await _startServer(
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

  group('dart_runner_mcp arguments', () {
    test('shows project path on startup', () async {
      final (process, stderrBuffer) = await _startServer(
        'bin/dart_runner_mcp.dart',
        ['.'],
      );

      process.kill();
      await process.exitCode;

      expect(stderrBuffer.toString(), contains('Project path:'));
    });

    test('uses current directory when no path specified', () async {
      final (process, stderrBuffer) = await _startServer(
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

  group('flutter_runner_mcp arguments', () {
    test('shows project path and FVM status', () async {
      final (process, stderrBuffer) = await _startServer(
        'bin/flutter_runner_mcp.dart',
        ['.'],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
      expect(stderr, contains('Using FVM:'));
    });
  });

  group('git_mcp arguments', () {
    test('shows git status and project path', () async {
      final (process, stderrBuffer) = await _startServer(
        'bin/git_mcp.dart',
        ['.'],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Is git repository:'));
      expect(stderr, contains('Project path:'));
    });
  });

  group('fetch_mcp arguments', () {
    test('shows user agent and respects robots.txt by default', () async {
      final (process, stderrBuffer) = await _startServer(
        'bin/fetch_mcp.dart',
        [],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('User Agent:'));
      expect(stderr, contains('Ignore robots.txt: false'));
    });

    test('accepts --ignore-robots-txt flag', () async {
      final (process, stderrBuffer) = await _startServer(
        'bin/fetch_mcp.dart',
        ['--ignore-robots-txt'],
      );

      process.kill();
      await process.exitCode;

      expect(stderrBuffer.toString(), contains('Ignore robots.txt: true'));
    });
  });

  group('convert_to_md_mcp arguments', () {
    test('starts without any arguments', () async {
      final (process, stderrBuffer) = await _startServer(
        'bin/convert_to_md_mcp.dart',
        [],
      );

      process.kill();
      await process.exitCode;

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Convert-to-MD MCP Server starting'));
    });
  });
}
