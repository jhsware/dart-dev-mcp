import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await compileAllServers();
  });

  group('file_edit_mcp arguments', () {
    test('shows error without arguments', () async {
      final result = await runServer('bin/file_edit_mcp.dart', []);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Usage: file_edit_mcp'));
    });

    test('shows allowed paths on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/file_edit_mcp.dart',
        ['./lib', './bin'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Allowed paths:'));
      expect(stderr, contains('lib'));
      expect(stderr, contains('bin'));
    });
  });

  group('dart_runner_mcp arguments', () {
    test('shows project path on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/dart_runner_mcp.dart',
        ['.'],
      );
      await stopServer(process);

      expect(stderrBuffer.toString(), contains('Project path:'));
    });

    test('uses current directory when no path specified', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/dart_runner_mcp.dart',
        [],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
      expect(stderr, contains('dart_dev_mcp'));
    });
  });

  group('flutter_runner_mcp arguments', () {
    test('shows project path and FVM status', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/flutter_runner_mcp.dart',
        ['.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
      expect(stderr, contains('Using FVM:'));
    });
  });

  group('git_mcp arguments', () {
    test('shows git status and project path', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/git_mcp.dart',
        ['.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Is git repository:'));
      expect(stderr, contains('Project path:'));
    });
  });

  group('fetch_mcp arguments', () {
    test('shows user agent and respects robots.txt by default', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/fetch_mcp.dart',
        [],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('User Agent:'));
      expect(stderr, contains('Ignore robots.txt: false'));
    });

    test('accepts --ignore-robots-txt flag', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/fetch_mcp.dart',
        ['--ignore-robots-txt'],
      );
      await stopServer(process);

      expect(stderrBuffer.toString(), contains('Ignore robots.txt: true'));
    });
  });

  group('convert_to_md_mcp arguments', () {
    test('starts without any arguments', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/convert_to_md_mcp.dart',
        [],
      );
      await stopServer(process);

      expect(stderrBuffer.toString(), contains('Convert-to-MD MCP Server starting'));
    });
  });
}
