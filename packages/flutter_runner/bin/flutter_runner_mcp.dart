import 'dart:convert';
import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Flutter Runner MCP Server
///
/// Provides Flutter program execution via FVM with polling support for long-running processes.
///
/// Usage: dart run bin/flutter_runner_mcp.dart --project-dir=PATH1 [--project-dir=PATH2 ...]
void main(List<String> arguments) async {
  final serverArgs = ServerArguments.parse(arguments);

  if (serverArgs.helpRequested) {
    _printUsage();
    exit(0);
  }

  // Validate required arguments
  if (serverArgs.projectDirs.isEmpty) {
    stderr.writeln('Error: at least one --project-dir is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  // Validate all project directories exist
  for (final dir in serverArgs.projectDirs) {
    final workingDir = Directory(dir);
    if (!await workingDir.exists()) {
      stderr.writeln('Error: Project path does not exist: $dir');
      exit(1);
    }
  }

  // Resolve FVM usage per project. A project uses FVM when it has a .fvm
  // directory (created by `fvm use <version>`). FVM is not required globally.
  final fvmResolver = FvmResolver(
    allowFallback: serverArgs.allowToolchainFallback,
  );
  if (serverArgs.allowToolchainFallback) {
    logWarning(
      'flutter-runner',
      '--allow-toolchain-fallback is set: projects that declare .fvm but '
          'lack the `fvm` binary will fall back to the system flutter with '
          'a warning (pinned SDK will NOT be used).',
    );
  }
  for (final dir in serverArgs.projectDirs) {
    final resolution = await fvmResolver.resolve(dir);
    if (resolution.fvmBinaryMissing) {
      logWarning(
        'flutter-runner',
        'Project $dir has .fvm but the `fvm` binary is not on PATH. '
            'Flutter commands for this project will fail until fvm is installed. '
            'Install from https://fvm.app/ or restart with --allow-toolchain-fallback.',
      );
    } else if (resolution.useFvm) {
      logInfo('flutter-runner', 'Project $dir -> using fvm (.fvm detected)');
    } else {
      logInfo(
          'flutter-runner', 'Project $dir -> using system flutter (no .fvm)');
    }
  }


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
- pub-run: Run 'fvm flutter pub run <package> [args...]' - commonly used for code
           generation (e.g. target='build_runner', args=['build', '--delete-conflicting-outputs']).
           The target parameter is REQUIRED and specifies the package to run.
- clean: Run 'fvm flutter clean' to clean build artifacts
- doctor: Run 'fvm flutter doctor' to check Flutter installation
- get_output: Get output chunks from a running or completed session
- list_sessions: List all active sessions
- cancel: Cancel a running session

For long-running operations, a session_id is returned.
Use get_output with the session_id to poll for output.''',
    inputSchema: ToolInputSchema(
      properties: {
        'project_dir': JsonSchema.string(
          description:
              'Project directory path. Must match one of the registered --project-dir values. REQUIRED for all operations.',
        ),
        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: [
            'analyze',
            'test',
            'run',
            'build',
            'pub-get',
            'pub-run',
            'clean',
            'doctor',
            'get_output',
            'list_sessions',
            'cancel',
          ],
        ),
        'target': JsonSchema.string(
          description:
              'Target file, directory, or build type. Used by analyze, test, run, build, and format. For pub-run this is the package name (REQUIRED), e.g. "build_runner".',
        ),
        'device': JsonSchema.string(
          description: 'Device ID to run on (for run operation)',
        ),
        'flavor': JsonSchema.string(
          description: 'Build flavor (for run/build operations)',
        ),
        'args': JsonSchema.array(
          items: JsonSchema.string(),
          description:
              'Additional arguments to pass to the Flutter command',
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
      required: ['project_dir'],
    ),
    callback: (args, extra) => _handleFlutterRunner(
        args, extra, serverArgs, sessionManager, fvmResolver),

  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('flutter-runner', 'Flutter Runner MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln(
      'Usage: flutter_runner_mcp --project-dir=PATH1 [--project-dir=PATH2 ...]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln(
      '  --project-dir=PATH             Path to a project directory (required, can be repeated)');
  stderr.writeln(
      '  --allow-toolchain-fallback     When .fvm is present but the `fvm` binary is');
  stderr.writeln(
      '                                 missing, log a warning and fall back to the');
  stderr.writeln(
      '                                 system flutter instead of erroring.');
  stderr.writeln(
      '  --help, -h                     Show this help message');
}


const _validOperations = [
  'analyze',
  'test',
  'run',
  'build',
  'pub-get',
  'pub-run',
  'clean',
  'doctor',
  'get_output',
  'list_sessions',
  'cancel',
];
Future<CallToolResult> _handleFlutterRunner(
  Map<String, dynamic> args,
  RequestHandlerExtra extra,
  ServerArguments serverArgs,
  SessionManager sessionManager,
  FvmResolver fvmResolver,
) async {
  // Validate project_dir is present and valid
  final projectDir = args['project_dir'] as String?;
  if (requireString(projectDir, 'project_dir') case final error?) {
    return error;
  }
  if (!serverArgs.projectDirs.contains(projectDir)) {
    return validationError('project_dir',
        'project_dir must be one of: ${serverArgs.projectDirs.join(", ")}');
  }

  final operation = args['operation'] as String?;
  if (requireStringOneOf(operation, 'operation', _validOperations)
      case final error?) {
    return error;
  }

  final workingDir = Directory(projectDir!);
  // Resolve per-project FVM usage (cached). If the project pins a Flutter
  // version via .fvm but the fvm binary is missing, fail fast with a clear
  // message rather than silently running the wrong SDK — unless the
  // operator opted into soft-fallback via --allow-toolchain-fallback, in
  // which case FvmResolver already downgraded the resolution and logged a
  // warning.
  final fvmResolution = await fvmResolver.resolve(projectDir);
  if (fvmResolution.fvmBinaryMissing) {
    return validationError(
      'project_dir',
      'Project $projectDir has a .fvm directory but the `fvm` binary was '
          'not found on PATH. Install fvm (https://fvm.app/), or restart '
          'the server with --allow-toolchain-fallback to allow a '
          'warning-and-fallback to the system flutter.',
    );
  }
  final useFvm = fvmResolution.useFvm;
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

      case 'pub-run':
        final target = args['target'] as String?;
        if (requireString(target, 'target') case final error?) {
          return error;
        }
        return _startFlutterCommandWithProgress(
          extra,
          workingDir,
          sessionManager,
          useFvm,
          'pub-run',
          ['pub', 'run', target!, ...?_getExtraArgs(args)],
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
        return _getOutput(
            sessionManager, sessionId, chunkIndex, maxChunks);

      case 'list_sessions':
        return _listSessions(sessionManager);

      case 'cancel':
        final sessionId = args['session_id'] as String?;
        return await _cancelSession(sessionManager, sessionId);

      default:
        return validationError(
            'operation', 'Unknown operation: $operation');
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
(String, List<String>) _getFlutterCommand(
    bool useFvm, List<String> flutterArgs) {
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
  final (executable, cmdArgs) =
      _getFlutterCommand(useFvm, flutterArgs);
  final commandStr = useFvm
      ? 'fvm flutter ${flutterArgs.join(' ')}'
      : 'flutter ${flutterArgs.join(' ')}';

  final sessionId =
      sessionManager.createSession(operation, commandStr);
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
      message:
          'Running $operation... (${allOutput.length} chars received)',
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
    final (executable, args) =
        _getFlutterCommand(useFvm, flutterArgs);
    final commandStr = useFvm
        ? 'fvm flutter ${flutterArgs.join(' ')}'
        : 'flutter ${flutterArgs.join(' ')}';

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

  final chunks = startIndex < totalChunks
      ? session.chunks.sublist(startIndex, endIndex)
      : <String>[];

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
    response['message'] =
        'All output has been retrieved. Operation complete.';
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

/// Per-project FVM resolution.
class FvmResolver {
  /// When true, projects that declare `.fvm/` but have no `fvm` binary on
  /// PATH are transparently downgraded to "use system flutter" with a
  /// single warning per project (the pinned SDK is NOT used). When false
  /// (default), the resolver reports `fvmBinaryMissing: true` and callers
  /// should fail fast.
  final bool allowFallback;

  final Map<String, FvmResolution> _cache = {};
  final Set<String> _fallbackWarned = {};
  bool? _fvmBinaryAvailable;

  FvmResolver({this.allowFallback = false});

  Future<FvmResolution> resolve(String projectDir) async {
    final cached = _cache[projectDir];
    if (cached != null) return cached;

    final fvmDir = Directory('$projectDir/.fvm');
    final hasFvmDir = await fvmDir.exists();

    if (!hasFvmDir) {
      final res = const FvmResolution(useFvm: false, fvmBinaryMissing: false);
      _cache[projectDir] = res;
      return res;
    }

    // .fvm exists - we need fvm on PATH to honor the pinned version.
    final fvmAvailable = await _checkFvmBinary();
    if (fvmAvailable) {
      final res = const FvmResolution(useFvm: true, fvmBinaryMissing: false);
      _cache[projectDir] = res;
      return res;
    }

    if (allowFallback) {
      if (_fallbackWarned.add(projectDir)) {
        logWarning(
          'flutter-runner',
          "Project $projectDir has .fvm but the 'fvm' binary is not on "
              "PATH. --allow-toolchain-fallback is set; falling back to "
              "the system flutter. The pinned SDK is NOT being used.",
        );
      }
      final res = const FvmResolution(useFvm: false, fvmBinaryMissing: false);
      _cache[projectDir] = res;
      return res;
    }

    final res = const FvmResolution(useFvm: false, fvmBinaryMissing: true);
    _cache[projectDir] = res;
    return res;
  }

  Future<bool> _checkFvmBinary() async {
    final cached = _fvmBinaryAvailable;
    if (cached != null) return cached;
    try {
      final result = await Process.run('which', ['fvm']);
      final available = result.exitCode == 0;
      _fvmBinaryAvailable = available;
      return available;
    } catch (_) {
      _fvmBinaryAvailable = false;
      return false;
    }
  }
}

/// Resolution for a single project_dir's FVM status.

class FvmResolution {
  /// True when the project has .fvm AND fvm is on PATH; commands should be
  /// prefixed with `fvm`.
  final bool useFvm;

  /// True when the project has .fvm but the `fvm` binary is missing on the
  /// host. Caller should surface a friendly install hint and not silently
  /// fall back to the system flutter (which would use the wrong SDK).
  final bool fvmBinaryMissing;

  const FvmResolution({
    required this.useFvm,
    required this.fvmBinaryMissing,
  });
}

