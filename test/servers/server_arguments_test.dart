import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await compileAllServers();
  });

  group('file_edit_mcp arguments', () {
    test('shows error without --project-dir', () async {
      final result = await runServer('bin/file_edit_mcp.dart', []);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });

    test('shows error without allowed paths', () async {
      final result = await runServer('bin/file_edit_mcp.dart', ['--project-dir=.']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('At least one allowed path is required'));
    });

    test('shows allowed paths on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/file_edit_mcp.dart',
        ['--project-dir=.', './lib', './bin'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Allowed paths:'));
      expect(stderr, contains('lib'));
      expect(stderr, contains('bin'));
    });

    test('shows project directory on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/file_edit_mcp.dart',
        ['--project-dir=.', './lib'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project directory:'));
    });
  });

  group('dart_runner_mcp arguments', () {
    test('shows project path on startup with --project-dir', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/dart_runner_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      expect(stderrBuffer.toString(), contains('Project path:'));
    });

    test('uses current directory when no --project-dir specified', () async {
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
    test('shows project path and FVM status with --project-dir', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/flutter_runner_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
      expect(stderr, contains('Using FVM:'));
    });

    test('uses current directory when no --project-dir specified', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/flutter_runner_mcp.dart',
        [],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
    });
  });

  group('git_mcp arguments', () {
    test('shows error without --project-dir', () async {
      final result = await runServer('bin/git_mcp.dart', []);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });

    test('shows git status and project path with --project-dir', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/git_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Is git repository:'));
      expect(stderr, contains('Project path:'));
    });

    test('shows allowed paths on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/git_mcp.dart',
        ['--project-dir=.', './lib', './bin'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Allowed paths:'));
      expect(stderr, contains('lib'));
      expect(stderr, contains('bin'));
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
      expect(stderr, contains('userAgent='));
      expect(stderr, contains('ignoreRobotsTxt=false'));
    });

    test('accepts --ignore-robots-txt flag', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/fetch_mcp.dart',
        ['--ignore-robots-txt'],
      );
      await stopServer(process);

      expect(stderrBuffer.toString(), contains('ignoreRobotsTxt=true'));
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

  group('planner_mcp arguments', () {
    test('shows error without --project-dir', () async {
      final result = await runServer('bin/planner_mcp.dart', []);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });

    test('shows project path and database location with --project-dir', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/planner_mcp.dart',
        ['--project-dir=.', '--db-path=.ai_coding_tool/db.sqlite'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
      expect(stderr, contains('Database:'));
      expect(stderr, contains('.ai_coding_tool'));
      expect(stderr, contains('db.sqlite'));
    });

    test('shows help with --help flag', () async {
      final result = await runServer('bin/planner_mcp.dart', ['--help']);

      expect(result.exitCode, 0);
      expect(result.stderr, contains('Usage: planner_mcp --project-dir=PATH'));
      expect(result.stderr, contains('.ai_coding_tool/db.sqlite'));
      expect(result.stderr, contains('INSTRUCTIONS.md'));
    });
  });

  group('code_index_mcp arguments', () {
    test('shows error without --db-path', () async {
      final result = await runServer(
          'bin/code_index_mcp.dart', ['--project-dir=.']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--db-path is required'));
    });

    test('shows error without --project-dir', () async {
      final result = await runServer(
          'bin/code_index_mcp.dart', ['--db-path=:memory:']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });

    test('shows help with --help flag', () async {
      final result = await runServer('bin/code_index_mcp.dart', ['--help']);

      expect(result.exitCode, 0);
      expect(result.stderr, contains('Usage: code_index_mcp'));
    });
  });
}
