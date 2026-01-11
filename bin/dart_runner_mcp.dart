import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:dart_dev_mcp/dart_dev_mcp.dart';

/// Dart Runner MCP Server
///
/// Provides Dart program execution with polling support for long-running processes.
///
/// Usage: dart run bin/dart_runner_mcp.dart --project-dir=PATH
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

  // Default to current directory if not specified
  projectDir ??= Directory.current.path;

  final workingDir = Directory(p.normalize(p.absolute(projectDir)));

  if (!await workingDir.exists()) {
    stderr.writeln('Error: Project path does not exist: $projectDir');
    exit(1);
  }

  // Check if it's a Dart project
  final pubspecFile = File(p.join(workingDir.path, 'pubspec.yaml'));
  if (!await pubspecFile.exists()) {
    stderr.writeln('Warning: No pubspec.yaml found in $projectDir');
    stderr.writeln('This may not be a Dart project.');
  }

  stderr.writeln('Dart Runner MCP Server starting...');
  stderr.writeln('Project path: ${workingDir.path}');

  final sessionManager = SessionManager();

  final server = McpServer(
    Implementation(name: 'dart-runner-mcp', version: '1.0.0'),
    options: ServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the dart-runner tool
  server.tool(
    'dart-runner',
    description: '''Run Dart commands with support for long-running processes.

Operations:
- analyze: Run 'dart analyze' to check for errors
- test: Run 'dart test' to execute tests
- run: Run 'dart run' to execute a Dart program
- format: Run 'dart format' to format code
- pub-get: Run 'dart pub get' to fetch dependencies
- get_output: Get output chunks from a running or completed session
- list_sessions: List all active sessions
- cancel: Cancel a running session

For long-running operations (analyze, test, run), a session_id is returned.
Use get_output with the session_id to poll for output.''',
    toolInputSchema: ToolInputSchema(
      properties: {
        'operation': {
          'type': 'string',
          'description': 'The operation to perform',
          'enum': [
            'analyze',
            'test',
            'run',
            'format',
            'pub-get',
            'get_output',
            'list_sessions',
            'cancel',
          ],
        },
        'target': {
          'type': 'string',
          'description':
              'Target file or directory for run/test/format operations. Default: current directory',
        },
        'args': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Additional arguments to pass to the Dart command',
        },
        'session_id': {
          'type': 'string',
          'description':
              'Session ID returned from run/test/analyze (required for get_output and cancel)',
        },
        'chunk_index': {
          'type': 'integer',
          'description':
              'Starting chunk index for get_output (default: 0). Use to paginate through output.',
        },
        'max_chunks': {
          'type': 'integer',
          'description':
              'Maximum number of chunks to return in get_output (default: 50, max: 200)',
        },
      },
    ),
    callback: ({args, extra}) =>
        _handleDartRunner(args, workingDir, sessionManager),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  stderr.writeln('Dart Runner MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln('Usage: dart_runner_mcp [--project-dir=PATH]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln('  --project-dir=PATH  Working directory for the project (default: current directory)');
  stderr.writeln('  --help, -h          Show this help message');
}



Future<CallToolResult> _handleDartRunner(
  Map<String, dynamic>? args,
  Directory workingDir,
  SessionManager sessionManager,
) async {
  final operation = args?['operation'] as String?;

  if (operation == null) {
    return textResult('Error: operation is required');
  }

  switch (operation) {
    case 'analyze':
      return _startDartCommand(
        workingDir,
        sessionManager,
        'analyze',
        ['analyze', ...?_getExtraArgs(args)],
      );

    case 'test':
      final target = args?['target'] as String?;
      return _startDartCommand(
        workingDir,
        sessionManager,
        'test',
        [
          'test',
          if (target != null) target,
          ...?_getExtraArgs(args),
        ],
      );

    case 'run':
      final target = args?['target'] as String?;
      return _startDartCommand(
        workingDir,
        sessionManager,
        'run',
        [
          'run',
          if (target != null) target,
          ...?_getExtraArgs(args),
        ],
      );

    case 'format':
      final target = args?['target'] as String? ?? '.';
      return _runDartCommandSync(
        workingDir,
        ['format', target, ...?_getExtraArgs(args)],
      );

    case 'pub-get':
      return _runDartCommandSync(
        workingDir,
        ['pub', 'get', ...?_getExtraArgs(args)],
      );

    case 'get_output':
      final sessionId = args?['session_id'] as String?;
      final chunkIndex = (args?['chunk_index'] as num?)?.toInt() ?? 0;
      final maxChunks =
          ((args?['max_chunks'] as num?)?.toInt() ?? 50).clamp(1, 200);
      return _getOutput(sessionManager, sessionId, chunkIndex, maxChunks);

    case 'list_sessions':
      return _listSessions(sessionManager);

    case 'cancel':
      final sessionId = args?['session_id'] as String?;
      return _cancelSession(sessionManager, sessionId);

    default:
      return textResult('Error: Unknown operation: $operation');
  }
}

List<String>? _getExtraArgs(Map<String, dynamic>? args) {
  final extraArgs = args?['args'];
  if (extraArgs is List) {
    return extraArgs.cast<String>();
  }
  return null;
}

/// Start a long-running Dart command and return session info
CallToolResult _startDartCommand(
  Directory workingDir,
  SessionManager sessionManager,
  String operation,
  List<String> dartArgs,
) {
  final sessionId = sessionManager.createSession(operation, dartArgs.join(' '));
  final session = sessionManager.getSession(sessionId)!;

  // Start the command
  final outputStream = streamCommand(
    workingDir,
    'dart',
    dartArgs,
    onProcessStarted: (process) => session.setProcess(process),
  );

  // Collect output in background
  session.collectOutput(outputStream);

  final response = {
    'status': 'started',
    'session_id': sessionId,
    'operation': operation,
    'command': 'dart ${dartArgs.join(' ')}',
    'message':
        'Operation started. Use get_output with session_id to retrieve output chunks.',
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
  } catch (e) {
    return textResult('Error running command: $e');
  }
}

/// Get output chunks from a session
CallToolResult _getOutput(
  SessionManager sessionManager,
  String? sessionId,
  int chunkIndex,
  int maxChunks,
) {
  if (sessionId == null || sessionId.isEmpty) {
    return textResult('Error: session_id is required');
  }

  final session = sessionManager.getSession(sessionId);
  if (session == null) {
    final response = {
      'error': 'Session not found',
      'session_id': sessionId,
    };
    return textResult(jsonEncode(response));
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
  if (sessionId == null || sessionId.isEmpty) {
    return textResult('Error: session_id is required');
  }

  final session = sessionManager.getSession(sessionId);
  if (session == null) {
    final response = {
      'error': 'Session not found',
      'session_id': sessionId,
    };
    return textResult(jsonEncode(response));
  }

  await sessionManager.removeSession(sessionId);

  final response = {
    'status': 'cancelled',
    'session_id': sessionId,
    'message': 'Session has been cancelled and removed.',
  };

  return textResult(jsonEncode(response));
}
