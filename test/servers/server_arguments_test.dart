import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_helpers.dart';


void main() {
  setUpAll(() async {
    await compileAllServers();
  });

  group('file_edit_mcp arguments', () {
    test('shows error without --project-dir', () async {
      final result = await runServer('packages/filesystem/bin/file_edit_mcp.dart', []);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });

    test('shows error without allowed paths', () async {
      final result = await runServer('packages/filesystem/bin/file_edit_mcp.dart', ['--project-dir=.']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('At least one allowed path is required'));
    });

    test('shows allowed paths on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/filesystem/bin/file_edit_mcp.dart',
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
        'packages/filesystem/bin/file_edit_mcp.dart',
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
        'packages/dart_runner/bin/dart_runner_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      expect(stderrBuffer.toString(), contains('Project path:'));
    });

    test('uses current directory when no --project-dir specified', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/dart_runner/bin/dart_runner_mcp.dart',
        [],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
      expect(stderr, contains(p.basename(Directory.current.path)));
    });
  });

  group('flutter_runner_mcp arguments', () {
    test('shows project path and FVM status with --project-dir', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/flutter_runner/bin/flutter_runner_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
      expect(stderr, contains('Using FVM:'));
    });

    test('uses current directory when no --project-dir specified', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/flutter_runner/bin/flutter_runner_mcp.dart',
        [],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project path:'));
    });
  });

  group('git_mcp arguments', () {
    test('shows error without --project-dir', () async {
      final result = await runServer('packages/git/bin/git_mcp.dart', []);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });

    test('shows git status and project path with --project-dir', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/git/bin/git_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Is git repository:'));
      expect(stderr, contains('Project path:'));
    });

    test('shows allowed paths on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/git/bin/git_mcp.dart',
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
        'packages/fetch/bin/fetch_mcp.dart',
        [],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('userAgent='));
      expect(stderr, contains('ignoreRobotsTxt=false'));
    });

    test('accepts --ignore-robots-txt flag', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/fetch/bin/fetch_mcp.dart',
        ['--ignore-robots-txt'],
      );
      await stopServer(process);

      expect(stderrBuffer.toString(), contains('ignoreRobotsTxt=true'));
    });
  });

  group('planner_mcp arguments', () {
    test('shows error without --project-dir', () async {
      final result = await runServer('packages/planner/bin/planner_mcp.dart', []);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });

    test('shows project path and database location with --project-dir', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/planner/bin/planner_mcp.dart',
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
      final result = await runServer('packages/planner/bin/planner_mcp.dart', ['--help']);

      expect(result.exitCode, 0);
      expect(result.stderr, contains('Usage: planner_mcp --project-dir=PATH'));
      expect(result.stderr, contains('.ai_coding_tool/db.sqlite'));
      expect(result.stderr, contains('INSTRUCTIONS.md'));
    });

    test('fails with non-existent project directory', () async {
      final result = await runServer(
        'packages/planner/bin/planner_mcp.dart',
        ['--project-dir=/nonexistent/path', '--db-path=:memory:'],
      );

      expect(result.exitCode, 1);
      expect(result.stderr, contains('does not exist'));
    });

    test('creates .ai_coding_tool directory if missing', () async {
      final tempDir = await Directory.systemTemp.createTemp('planner_cli_test_');
      try {
        final aiToolDir = Directory(p.join(tempDir.path, '.ai_coding_tool'));
        expect(await aiToolDir.exists(), isFalse);

        final dbPath = p.join(tempDir.path, '.ai_coding_tool', 'db.sqlite');
        final (process, _) = await startServer(
          'packages/planner/bin/planner_mcp.dart',
          ['--project-dir=${tempDir.path}', '--db-path=$dbPath'],
        );

        // Check directory was created
        expect(await aiToolDir.exists(), isTrue);

        // Check database was created
        final dbFile = File(dbPath);
        expect(await dbFile.exists(), isTrue);

        await stopServer(process);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });


  group('code_index_mcp arguments', () {
    test('shows error without --db-path', () async {
      final result = await runServer(
          'packages/code_index/bin/code_index_mcp.dart', ['--project-dir=.']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--db-path is required'));
    });

    test('shows error without --project-dir', () async {
      final result = await runServer(
          'packages/code_index/bin/code_index_mcp.dart', ['--db-path=:memory:']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });

    test('shows help with --help flag', () async {
      final result = await runServer('packages/code_index/bin/code_index_mcp.dart', ['--help']);

      expect(result.exitCode, 0);
      expect(result.stderr, contains('Usage: code_index_mcp'));
    });
  });
}
