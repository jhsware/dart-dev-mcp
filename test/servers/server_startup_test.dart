import 'dart:io';

import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await compileAllServers();
  });

  group('MCP Server Startup', () {
    test('filesystem_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/filesystem/bin/filesystem_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      expect(
        stderrBuffer.toString(),
        contains('Filesystem MCP Server running on stdio'),
      );
    });

    test('fetch_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/fetch/bin/fetch_mcp.dart',
        [],
      );
      await stopServer(process);

      expect(stderrBuffer.toString(), contains('Server running on stdio'));
    });

    test('dart_runner_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/dart_runner/bin/dart_runner_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      expect(
        stderrBuffer.toString(),
        contains('Dart Runner MCP Server running on stdio'),
      );
    });

    test('flutter_runner_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/flutter_runner/bin/flutter_runner_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      expect(
        stderrBuffer.toString(),
        contains('Flutter Runner MCP Server running on stdio'),
      );
    });

    test('git_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/git/bin/git_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      expect(
        stderrBuffer.toString(),
        contains('Git MCP Server running on stdio'),
      );
    });

    test('planner_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'packages/planner/bin/planner_mcp.dart',
        ['--project-dir=.'],
      );
      await stopServer(process);

      expect(
        stderrBuffer.toString(),
        contains('Planner MCP Server running on stdio'),
      );
    });

    test('code_index_mcp starts successfully', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'code_index_startup_',
      );
      try {
        final (process, stderrBuffer) = await startServer(
          'packages/code_index/bin/code_index_mcp.dart',
          ['--project-dir=.', '--planner-data-root=${tempDir.path}'],
        );
        await stopServer(process);

        expect(
          stderrBuffer.toString(),
          contains('Code Index MCP Server running on stdio'),
        );
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}
