import 'dart:convert';
import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;

/// Flutter Runner MCP Server
///
/// Provides Flutter program execution via FVM with polling support for long-running processes.
///
/// Usage: dart run bin/flutter_runner_mcp.dart [--project-dir=PATH]
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

  // Check if FVM is available
  final fvmCheck = await Process.run('which', ['fvm']);
  final useFvm = fvmCheck.exitCode == 0;
  
  if (!useFvm) {
    logWarning('flutter-runner', 'FVM not found. Using flutter directly.');
  }

  logInfo('flutter-runner', 'Flutter Runner MCP Server starting...');
  if (cliWorkingDir != null) {
    logInfo('flutter-runner', 'CLI project path: ${cliWorkingDir.path}');
  } else {
    logInfo('flutter-runner', 'No CLI project directory set, project_root param required in tool calls');
  }
  logInfo('flutter-runner', 'Using FVM: $useFvm');

  final sessionManager = SessionManager();

  final server = McpServer(
    Implementation(name: 'flutter-runner-mcp', version: '1.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the flutter-runner tool
  server.registerTool(
    'flutter-runner',
    description: '''Run Flutter commands via FVM with support for long-running processes.

Operations:
- analyze: Run 'fvm flutter analyze' to check for errors (supports target file/directory)
- test: Run 'fvm flutter test' to execute tests
- run: Run 'fvm flutter run' to run the app
- build: Run 'fvm flutter build' to build the app
- pub-get: Run 'fvm flutter pub get' to fetch dependencies
- clean: Run 'fvm flutter clean' to clean build artifacts
- doctor: Run 'fvm flutter doctor' to check Flutter installation
- get_output: Get output chunks from a running or completed session
- list_sessions: List all active sessions
- cancel: Cancel a running session

For long-running operations, a session_id is returned.
Use get_output with the session_id to poll for output.''',
    inputSchema: ToolInputSchema(
      properties: {
        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: [
            'analyze',
            'test',
            'run',
            'build',
            'pub-get',
            'clean',
            'doctor',
            'get_output',
            'list_sessions',
            'cancel',
          ],
        ),
        'target': JsonSchema.string(
          description:
              'Target file, directory, or build type. Used by analyze, test, run, build, and format.',
        ),
        'device': JsonSchema.string(
          description: 'Device ID to run on (for run operation)',
        ),
        'flavor': JsonSchema.string(
          description: 'Build flavor (for run/build operations)',
        ),
        'args': JsonSchema.array(
          items: JsonSchema.string(),
          description: 'Additional arguments to pass to the Flutter command',
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
        _handleFlutterRunner(args, extra, cliWorkingDir, sessionManager, useFvm),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('flutter-runner', 'Flutter Runner MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln('Usage: flutter_runner_mcp [--project-dir=PATH]');
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
  'build',
  'pub-get',
  'clean',
  'doctor',
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

Future<CallToolResult> _handleFlutterRunner(
  Map<String, dynamic> args,
  RequestHandlerExtra extra,
  Directory? cliWorkingDir,
  SessionManager sessionManager,
  bool useFvm,
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
        return _startFlutterCommandWithProgress(
          extra,
          workingDir,
          sessionManager,
          useFvm,
          'analyze',
          ['analyze', ?target, ...?_getExtraArgs(args)],
        );

      case 'test':
        final target = args['target'] as String?;
        return _startFlutterCommandWithProgress(
          extra,
          workingDir,
          sessionManager,
          useFvm,
          'test',
          [
            'test',
            '--reporter',
            'silent',
            ?target,
            ...?_getExtraArgs(args),
          ],
        );

      case 'run':
        final device = args['device'] as String?;
        final flavor = args['flavor'] as String?;
        return _startFlutterCommandWithProgress(
          extra,
          workingDir,
          sessionManager,
          useFvm,
          'run',
          [
            'run',
            if (device != null) ...['-d', device],
            if (flavor != null) ...['--flavor', flavor],
            ...?_getExtraArgs(args),
          ],
        );

      case 'build':
        final target = args['target'] as String? ?? 'apk';
        final flavor = args['flavor'] as String?;
        return _startFlutterCommandWithProgress(
          extra,
          workingDir,
          sessionManager,
          useFvm,
          'build',
          [
            'build',
            target,
            if (flavor != null) ...['--flavor', flavor],
            ...?_getExtraArgs(args),
          ],
        );

      case 'pub-get':
        return await _runFlutterCommandSync(
          workingDir,
          useFvm,
          ['pub', 'get', ...?_getExtraArgs(args)],
        );

      case 'clean':
        return await _runFlutterCommandSync(
          workingDir,
          useFvm,
          ['clean', ...?_getExtraArgs(args)],
        );

      case 'doctor':
        return await _runFlutterCommandSync(
          workingDir,
          useFvm,
          ['doctor', ...?_getExtraArgs(args)],
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
    return errorResult('flutter-runner:$operation', e, stackTrace, {
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

/// Get the Flutter executable and arguments
(String, List<String>) _getFlutterCommand(bool useFvm, List<String> flutterArgs) {
  if (useFvm) {
    return ('fvm', ['flutter', ...flutterArgs]);
  } else {
    return ('flutter', flutterArgs);
  }
}

/// Start a long-running Flutter command with progress notifications
Future<CallToolResult> _startFlutterCommandWithProgress(
  RequestHandlerExtra extra,
  Directory workingDir,
  SessionManager sessionManager,
  bool useFvm,
  String operation,
  List<String> flutterArgs,
) async {
  final (executable, cmdArgs) = _getFlutterCommand(useFvm, flutterArgs);
  final commandStr = useFvm
      ? 'fvm flutter ${flutterArgs.join(' ')}'
      : 'flutter ${flutterArgs.join(' ')}';

  final sessionId = sessionManager.createSession(operation, commandStr);
  final session = sessionManager.getSession(sessionId)!;

  final outputStream = streamCommand(
    workingDir,
    executable,
    cmdArgs,
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
    'command': commandStr,
    'output': allOutput.toString(),
  };

  return textResult(jsonEncode(response));
}

/// Run a short Flutter command synchronously
Future<CallToolResult> _runFlutterCommandSync(
  Directory workingDir,
  bool useFvm,
  List<String> flutterArgs,
) async {
  try {
    final (executable, args) = _getFlutterCommand(useFvm, flutterArgs);
    final commandStr = useFvm ? 'fvm flutter ${flutterArgs.join(' ')}' : 'flutter ${flutterArgs.join(' ')}';
    
    final result = await runCommand(workingDir, executable, args);

    final output = StringBuffer();
    output.writeln('Command: $commandStr');
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
    return errorResult('flutter-runner:command', e, stackTrace, {
      'command': 'flutter ${flutterArgs.join(' ')}',
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
