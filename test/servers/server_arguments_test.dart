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

    test('shows project dirs on startup', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/filesystem/bin/file_edit_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project dirs:'));
      expect(stderr, contains(p.basename(Directory.current.path)));
    });

    test('starts with multiple --project-dir flags', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/filesystem/bin/file_edit_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('File Edit MCP Server starting'));
      expect(stderr, contains('Project dirs:'));
    });
  });

  group('dart_runner_mcp arguments', () {
    test('shows project dirs on startup with --project-dir', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/dart_runner/bin/dart_runner_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project dirs:'));
      expect(stderr, contains(p.basename(Directory.current.path)));
    });

    test('errors without --project-dir', () async {
      final result = await runServer(
        'packages/dart_runner/bin/dart_runner_mcp.dart',
        [],
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });
  });

  group('flutter_runner_mcp arguments', () {
    test('logs per-project FVM resolution with --project-dir', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/flutter_runner/bin/flutter_runner_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      // flutter_runner logs "Project <dir> -> using fvm" or
      // "Project <dir> -> using system flutter (no .fvm)" per project.
      expect(stderr, contains('-> using'));
      expect(stderr, contains(p.basename(Directory.current.path)));
    });

    test('errors without --project-dir', () async {
      final result = await runServer(
        'packages/flutter_runner/bin/flutter_runner_mcp.dart',
        [],
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });
  });

  group('git_mcp arguments', () {
    test('shows error without --project-dir', () async {
      final result = await runServer('packages/git/bin/git_mcp.dart', []);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--project-dir is required'));
    });

    test('shows project dirs and signing info with --project-dir', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/git/bin/git_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      final stderr = stderrBuffer.toString();
      expect(stderr, contains('Project dirs:'));
      expect(stderr, contains('Signing:'));
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

    test('fails with non-existent project directory', () async {
      final result = await runServer(
        'packages/planner/bin/planner_mcp.dart',
        ['--project-dir=/nonexistent/path'],
      );

      expect(result.exitCode, 1);
      expect(result.stderr, contains('does not exist'));
    });

    test('shows help with --help flag', () async {
      final result =
          await runServer('packages/planner/bin/planner_mcp.dart', ['--help']);

      expect(result.exitCode, 0);
      expect(result.stderr, contains('Usage: planner_mcp --project-dir=PATH'));
      expect(result.stderr, contains('--server-url'));
    });
  });


  group('code_index_mcp arguments', () {
    test('shows error without --planner-data-root', () async {
      final result = await runServer(
          'packages/code_index/bin/code_index_mcp.dart', ['--project-dir=.']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('--planner-data-root is required'));
    });

    test('shows error without --project-dir', () async {
      final tempDir = await Directory.systemTemp.createTemp('code_index_args_');
      try {
        final result = await runServer(
            'packages/code_index/bin/code_index_mcp.dart',
            ['--planner-data-root=${tempDir.path}']);

        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('--project-dir is required'));
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('shows help with --help flag', () async {
      final result = await runServer(
          'packages/code_index/bin/code_index_mcp.dart', ['--help']);

      expect(result.exitCode, 0);
      expect(result.stderr, contains('Usage: code_index_mcp'));
      expect(result.stderr, contains('--planner-data-root'));
    });
  });
}
