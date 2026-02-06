import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    await compileAllServers();
  });

  group('MCP Server Startup', () {
    test('file_edit_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/file_edit_mcp.dart',
        ['--project-dir=.', './lib', './bin', './test'],
      );
      await stopServer(process);

      expect(
        stderrBuffer.toString(),
        contains('File Edit MCP Server running on stdio'),
      );
    });

    test('convert_to_md_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/convert_to_md_mcp.dart',
        [],
      );
      await stopServer(process);

      expect(
        stderrBuffer.toString(),
        contains('Convert-to-MD MCP Server running on stdio'),
      );
    });

    test('fetch_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/fetch_mcp.dart',
        [],
      );
      await stopServer(process);

      expect(
        stderrBuffer.toString(),
        contains('Server running on stdio'),
      );
    });

    test('dart_runner_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/dart_runner_mcp.dart',
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
        'bin/flutter_runner_mcp.dart',
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
        'bin/git_mcp.dart',
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
        'bin/planner_mcp.dart',
        ['--project-dir=.', '--db-path=:memory:'],
      );
      await stopServer(process);

      expect(
        stderrBuffer.toString(),
        contains('Planner MCP Server running on stdio'),
      );
    });

    test('code_index_mcp starts successfully', () async {
      final (process, stderrBuffer) = await startServer(
        'bin/code_index_mcp.dart',
        ['--project-dir=.', '--db-path=:memory:'],
      );
      await stopServer(process);

      expect(
        stderrBuffer.toString(),
        contains('Code Index MCP Server running on stdio'),
      );
    });
  });
}
