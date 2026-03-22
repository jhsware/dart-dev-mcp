import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:jhsware_code_shared_libs/shared_libs.dart';

/// Dart Runner MCP Server
///
/// Provides Dart program execution with polling support for long-running processes.
///
/// Usage: dart run bin/dart_runner_mcp.dart [--project-dir=PATH]
///
/// When project_root is passed as a tool call parameter, it overrides
/// the CLI --project-dir for that invocation.
void main(List<String> arguments) async {
  String? projectDir;

  // Parse arguments
  for (final arg in arguments) {
    if (arg.startsWith('--project-dir=')) {
      projectDir = arg.substring('--project-dir='.length);
    } else if (arg == '--help' || arg == '-h') {
      _printUsage();
      exit(0);
    }
  }

  // CLI-provided default (used as fallback when project_root not in tool call)
  Directory? cliWorkingDir;

  if (projectDir != null && projectDir.isNotEmpty) {
    cliWorkingDir = Directory(p.normalize(p.absolute(projectDir)));

    if (!await cliWorkingDir.exists()) {
      stderr.writeln('Error: Project path does not exist: $projectDir');
      exit(1);
    }
  }

  logInfo('dart-runner', 'Dart Runner MCP Server starting...');
  if (cliWorkingDir != null) {
    logInfo('dart-runner', 'CLI project path: ${cliWorkingDir.path}');
  } else {
    logInfo('dart-runner', 'No CLI project directory set, project_root param required in tool calls');
  }

  final sessionManager = SessionManager();

  final server = McpServer(
    Implementation(name: 'dart-runner-mcp', version: '1.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the dart-runner tool
  server.registerTool(
    'dart-runner',
    description: '''Run Dart commands with support for long-running processes.

Operations:
- analyze: Run 'dart analyze' to check for errors (supports target file/directory)
- test: Run 'dart test' to execute tests
- run: Run 'dart run' to execute a Dart program
- format: Run 'dart format' to format code
- pub-get: Run 'dart pub get' to fetch dependencies
- get_output: Get output chunks from a running or completed session
- list_sessions: List all active sessions
- cancel: Cancel a running session

For long-running operations (analyze, test, run), a session_id is returned.
Use get_output with the session_id to poll for output.''',
    inputSchema: ToolInputSchema(
      properties: {
        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: [
            'analyze',
            'test',
            'run',
            'format',
            'pub-get',
            'get_output',
            'list_sessions',
            'cancel',
          ],
        ),
        'target': JsonSchema.string(
          description:
              'Target file or directory for run/test/analyze/format operations. Default: current directory',
        ),
        'args': JsonSchema.array(
          items: JsonSchema.string(),
          description: 'Additional arguments to pass to the Dart command',
        ),
        'session_id': JsonSchema.string(
          description:
              'Session ID returned from run/test/analyze (required for get_output and cancel)',
        ),
        'chunk_index': JsonSchema.integer(
          description:
              'Starting chunk index for get_output (default: 0). Use to paginate through output.',
        ),
        'max_chunks': JsonSchema.integer(
          description:
              'Maximum number of chunks to return in get_output (default: 50, max: 200)',
        ),
      },
    ),
    callback: (args, extra) =>
        _handleDartRunner(args, extra, cliWorkingDir, sessionManager),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('dart-runner', 'Dart Runner MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln('Usage: dart_runner_mcp [--project-dir=PATH]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln('  --project-dir=PATH  Working directory for the project (fallback)');
  stderr.writeln('  --help, -h          Show this help message');
  stderr.writeln('');
  stderr.writeln('Note: When project_root is provided in a tool call, it overrides --project-dir.');
}

const _validOperations = [
  'analyze',
  'test',
  'run',
  'format',
  'pub-get',
  'get_output',
  'list_sessions',
  'cancel',
];

/// Resolve workingDir from project_root parameter or CLI fallback.
Directory? _resolveWorkingDir(
  Map<String, dynamic> args,
  Directory? cliWorkingDir,
) {
  final projectRoot = args['project_root'] as String?;

  if (projectRoot != null && projectRoot.isNotEmpty) {
    return Directory(p.normalize(p.absolute(projectRoot)));
  }

  return cliWorkingDir;
}

Future<CallToolResult> _handleDartRunner(
  Map<String, dynamic> args,
  RequestHandlerExtra extra,
  Directory? cliWorkingDir,
  SessionManager sessionManager,
) async {
  final operation = args['operation'] as String?;

  if (requireStringOneOf(operation, 'operation', _validOperations) case final error?) {
    return error;
  }

  // Resolve working directory
  final workingDir = _resolveWorkingDir(args, cliWorkingDir);
  if (workingDir == null) {
    return validationError('project_root',
        'No project_root provided and no CLI --project-dir configured. '
        'Either pass project_root in the tool call or start the server with --project-dir.');
  }

  try {
    switch (operation) {
      case 'analyze':
        final target = args['target'] as String?;
        return _startDartCommandWithProgress(
          extra,
          workingDir,
          sessionManager,
          'analyze',
          ['analyze', ?target, ...?_getExtraArgs(args)],
        );

      case 'test':
        final target = args['target'] as String?;
        return _startDartCommandWithProgress(
          extra,
          workingDir,
          sessionManager,
          'test',
          [
            'test',
            ?target,
            ...?_getExtraArgs(args),
          ],
        );

      case 'run':
        final target = args['target'] as String?;
        return _startDartCommandWithProgress(
          extra,
          workingDir,
          sessionManager,
          'run',
          [
            'run',
            ?target,
            ...?_getExtraArgs(args),
          ],
        );
      case 'format':
        final target = args['target'] as String? ?? '.';
        return await _runDartCommandSync(
          workingDir,
          ['format', target, ...?_getExtraArgs(args)],
        );

      case 'pub-get':
        return await _runDartCommandSync(
          workingDir,
          ['pub', 'get', ...?_getExtraArgs(args)],
        );

      case 'get_output':
        final sessionId = args['session_id'] as String?;
        final chunkIndex = (args['chunk_index'] as num?)?.toInt() ?? 0;
        final maxChunks =
            ((args['max_chunks'] as num?)?.toInt() ?? 50).clamp(1, 200);
        return _getOutput(sessionManager, sessionId, chunkIndex, maxChunks);

      case 'list_sessions':
        return _listSessions(sessionManager);

      case 'cancel':
        final sessionId = args['session_id'] as String?;
        return await _cancelSession(sessionManager, sessionId);

      default:
        return validationError('operation', 'Unknown operation: $operation');
    }
  } catch (e, stackTrace) {
    return errorResult('dart-runner:$operation', e, stackTrace, {
      'operation': operation,
    });
  }
}


List<String>? _getExtraArgs(Map<String, dynamic> args) {
  final extraArgs = args['args'];
  if (extraArgs is List) {
    return extraArgs.cast<String>();
  }
  return null;
}

/// Start a long-running Dart command and return session info
/// Start a long-running Dart command with progress notifications
Future<CallToolResult> _startDartCommandWithProgress(
  RequestHandlerExtra extra,
  Directory workingDir,
  SessionManager sessionManager,
  String operation,
  List<String> dartArgs,
) async {
  final sessionId = sessionManager.createSession(operation, dartArgs.join(' '));
  final session = sessionManager.getSession(sessionId)!;

  final outputStream = streamCommand(
    workingDir,
    'dart',
    dartArgs,
    onProcessStarted: (process) => session.setProcess(process),
  );

  final allOutput = StringBuffer();
  var chunkCount = 0;

  await for (final chunk in outputStream) {
    session.chunks.add(chunk);
    allOutput.write(chunk);
    chunkCount++;

    // Send progress notification with latest output
    await extra.sendProgress(
      chunkCount.toDouble(),
      message: 'Running $operation... (${allOutput.length} chars received)',
    );
  }

  session.isComplete = true;

  // Return final complete result
  final response = {
    'status': 'completed',
    'session_id': sessionId,
    'operation': operation,
    'command': 'dart ${dartArgs.join(' ')}',
    'output': allOutput.toString(),
  };

  return textResult(jsonEncode(response));
}
/// Run a short Dart command synchronously
Future<CallToolResult> _runDartCommandSync(
  Directory workingDir,
  List<String> dartArgs,
) async {
  try {
    final result = await runCommand(workingDir, 'dart', dartArgs);

    final output = StringBuffer();
    output.writeln('Command: dart ${dartArgs.join(' ')}');
    output.writeln('Exit code: ${result.exitCode}');
    output.writeln('');

    if ((result.stdout as String).isNotEmpty) {
      output.writeln('Output:');
      output.writeln(result.stdout);
    }

    if ((result.stderr as String).isNotEmpty) {
      output.writeln('Errors:');
      output.writeln(result.stderr);
    }

    return textResult(output.toString());
  } catch (e, stackTrace) {
    return errorResult('dart-runner:command', e, stackTrace, {
      'command': 'dart ${dartArgs.join(' ')}',
    });
  }
}

/// Get output chunks from a session
CallToolResult _getOutput(
  SessionManager sessionManager,
  String? sessionId,
  int chunkIndex,
  int maxChunks,
) {
  if (requireString(sessionId, 'session_id') case final error?) {
    return error;
  }

  final session = sessionManager.getSession(sessionId!);
  if (session == null) {
    return notFoundError('Session', sessionId);
  }

  // Get the requested chunk range
  final totalChunks = session.chunks.length;
  final startIndex = chunkIndex.clamp(0, totalChunks);
  final endIndex = (startIndex + maxChunks).clamp(0, totalChunks);

  final chunks =
      startIndex < totalChunks ? session.chunks.sublist(startIndex, endIndex) : <String>[];

  final hasMoreChunks = endIndex < totalChunks;
  final nextChunkIndex = hasMoreChunks ? endIndex : null;

  final response = <String, dynamic>{
    'session_id': sessionId,
    'operation': session.operation,
    'description': session.description,
    'is_complete': session.isComplete,
    'total_chunks': totalChunks,
    'chunk_index': startIndex,
    'chunks_returned': chunks.length,
    'has_more_chunks': hasMoreChunks || !session.isComplete,
    'next_chunk_index': nextChunkIndex,
    'output': chunks.join(''),
  };

  // Add guidance
  if (!session.isComplete && !hasMoreChunks) {
    response['message'] =
        'Operation still running. Poll again with the same chunk_index to get new output.';
  } else if (hasMoreChunks) {
    response['message'] =
        'More chunks available. Call get_output with chunk_index: $nextChunkIndex';
  } else if (session.isComplete && !hasMoreChunks) {
    response['message'] = 'All output has been retrieved. Operation complete.';
  }

  return textResult(jsonEncode(response));
}

/// List all sessions
CallToolResult _listSessions(SessionManager sessionManager) {
  // Clean up old sessions
  sessionManager.cleanupOldSessions();

  final sessions = sessionManager.allSessions
      .map((s) => {
            'session_id': s.id,
            'operation': s.operation,
            'description': s.description,
            'is_complete': s.isComplete,
            'chunks_collected': s.chunks.length,
            'started_at': s.startedAt.toIso8601String(),
          })
      .toList();

  final response = {
    'sessions': sessions,
    'total': sessions.length,
  };

  return textResult(jsonEncode(response));
}

/// Cancel a running session
Future<CallToolResult> _cancelSession(
  SessionManager sessionManager,
  String? sessionId,
) async {
  if (requireString(sessionId, 'session_id') case final error?) {
    return error;
  }

  final session = sessionManager.getSession(sessionId!);
  if (session == null) {
    return notFoundError('Session', sessionId);
  }

  await sessionManager.removeSession(sessionId);

  final response = {
    'status': 'cancelled',
    'session_id': sessionId,
    'message': 'Session has been cancelled and removed.',
  };

  return textResult(jsonEncode(response));
}
