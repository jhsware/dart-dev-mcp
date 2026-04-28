import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

/// Dart Runner MCP Server
///
/// Provides Dart program execution with polling support for long-running processes.
///
/// Usage: dart run bin/dart_runner_mcp.dart --project-dir=PATH1 [--project-dir=PATH2 ...]
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

  logInfo('dart-runner', 'Dart Runner MCP Server starting...');
  logInfo('dart-runner',
      'Project dirs: ${serverArgs.projectDirs.join(", ")}');
  if (serverArgs.allowToolchainFallback) {
    logWarning(
      'dart-runner',
      '--allow-toolchain-fallback is set: projects that declare '
          'shell.nix/flake.nix but lack nix-shell/nix will fall back to '
          'the system dart with a warning (pinned SDK will NOT be used).',
    );
  }

  // Prime the nix-kind cache and log detected nix projects so operators
  // can see at a glance which projects will be wrapped in nix-shell.
  for (final dir in serverArgs.projectDirs) {
    final kind = _detectNixKind(Directory(dir));
    switch (kind) {
      case _NixKind.shellNix:
        logInfo('dart-runner',
            'Detected shell.nix in $dir — dart commands will run via nix-shell.');
      case _NixKind.flakeNix:
        logInfo('dart-runner',
            'Detected flake.nix in $dir — dart commands will run via nix develop.');
      case _NixKind.none:
        break;
    }
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
- pub-run: Run 'dart pub run <package> [args...]' - used for code generation
           (e.g. target='build_runner', args=['build', '--delete-conflicting-outputs']).
           The target parameter is REQUIRED and specifies the package to run.
           Note: For modern Dart projects, prefer the 'run' operation with
           target='<package>:<executable>' (e.g. 'build_runner:build_runner').
- get_output: Get output chunks from a running or completed session
- list_sessions: List all active sessions
- cancel: Cancel a running session

For long-running operations (analyze, test, run), a session_id is returned.
Use get_output with the session_id to poll for output.

Use 'working_dir' (optional) to run commands from a sub-directory of project_dir —
useful for monorepo packages (e.g. working_dir='packages/foo' for code generation).''',

    inputSchema: ToolInputSchema(
      properties: {
        'project_dir': JsonSchema.string(
          description:
              'Project directory path. Must match one of the registered --project-dir values. REQUIRED for all operations.',
        ),
        'working_dir': JsonSchema.string(
          description:
              'Optional sub-directory within project_dir to run the command from. '
              'Relative path only (no absolute, no "..", no hidden segments). '
              'Example: working_dir="packages/foo" for monorepo code generation.',
        ),

        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: [
            'analyze',
            'test',
            'run',
            'format',
            'pub-get',
            'pub-run',
            'get_output',
            'list_sessions',
            'cancel',
          ],
        ),
        'target': JsonSchema.string(
          description:
              'Target file or directory for run/test/analyze/format operations. Default: current directory. For pub-run this is the package name (REQUIRED), e.g. "build_runner".',
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
      required: ['project_dir'],
    ),
    callback: (args, extra) =>
        _handleDartRunner(args, extra, serverArgs, sessionManager),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('dart-runner', 'Dart Runner MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln(
      'Usage: dart_runner_mcp --project-dir=PATH1 [--project-dir=PATH2 ...]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln(
      '  --project-dir=PATH             Path to a project directory (required, can be repeated)');
  stderr.writeln(
      '  --allow-toolchain-fallback     When shell.nix/flake.nix is present but');
  stderr.writeln(
      '                                 nix-shell/nix is missing, log a warning and');
  stderr.writeln(
      '                                 fall back to the system dart instead of erroring.');
  stderr.writeln(
      '  --help, -h                     Show this help message');
}


const _validOperations = [
  'analyze',
  'test',
  'run',
  'format',
  'pub-get',
  'pub-run',
  'get_output',
  'list_sessions',
  'cancel',
];

Future<CallToolResult> _handleDartRunner(
  Map<String, dynamic> args,
  RequestHandlerExtra extra,
  ServerArguments serverArgs,
  SessionManager sessionManager,
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

  final projectRoot = Directory(projectDir!);
  final allowFallback = serverArgs.allowToolchainFallback;

  // Resolve optional working_dir for command-executing operations
  final workingDirArg = args['working_dir'] as String?;
  final resolved = resolveWorkingDir(projectRoot, workingDirArg);
  if (resolved.error != null) {
    return validationError('working_dir', resolved.error!);
  }
  final workingDir = resolved.directory!;

  try {
    switch (operation) {
      case 'analyze':
        final target = args['target'] as String?;
        return _startDartCommandWithProgress(
          extra,
          projectRoot,
          workingDir,
          sessionManager,
          'analyze',
          ['analyze', ?target, ...?_getExtraArgs(args)],
          allowFallback: allowFallback,
        );

      case 'test':
        final target = args['target'] as String?;
        return _startDartCommandWithProgress(
          extra,
          projectRoot,
          workingDir,
          sessionManager,
          'test',
          [
            'test',
            ?target,
            ...?_getExtraArgs(args),
          ],
          allowFallback: allowFallback,
        );

      case 'run':
        final target = args['target'] as String?;
        return _startDartCommandWithProgress(
          extra,
          projectRoot,
          workingDir,
          sessionManager,
          'run',
          [
            'run',
            ?target,
            ...?_getExtraArgs(args),
          ],
          allowFallback: allowFallback,
        );
      case 'format':
        final target = args['target'] as String? ?? '.';
        return await _runDartCommandSync(
          projectRoot,
          workingDir,
          ['format', target, ...?_getExtraArgs(args)],
          allowFallback: allowFallback,
        );
      case 'pub-get':
        return await _runDartCommandSync(
          projectRoot,
          workingDir,
          ['pub', 'get', ...?_getExtraArgs(args)],
          allowFallback: allowFallback,
        );

      case 'pub-run':
        final target = args['target'] as String?;
        if (requireString(target, 'target') case final error?) {
          return error;
        }
        return _startDartCommandWithProgress(
          extra,
          projectRoot,
          workingDir,
          sessionManager,
          'pub-run',
          ['pub', 'run', target!, ...?_getExtraArgs(args)],
          allowFallback: allowFallback,
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

/// Kind of nix environment detected for a project directory.
enum _NixKind { none, shellNix, flakeNix }

/// Cache of nix-kind detection keyed on absolute project directory.
/// Avoids re-checking the filesystem on every MCP invocation.
final Map<String, _NixKind> _nixKindCache = {};

/// Detect whether a project uses nix-shell / nix flake.
///
/// Preference order: `shell.nix` > `flake.nix` > none.
/// `shell.nix` wins because a project may ship both (flake for builds,
/// shell.nix for dev env) and we specifically want the dev-env Dart SDK.
_NixKind _detectNixKind(Directory workingDir) {
  final key = workingDir.path;
  final cached = _nixKindCache[key];
  if (cached != null) return cached;

  _NixKind kind;
  if (File('${workingDir.path}/shell.nix').existsSync()) {
    kind = _NixKind.shellNix;
  } else if (File('${workingDir.path}/flake.nix').existsSync()) {
    kind = _NixKind.flakeNix;
  } else {
    kind = _NixKind.none;
  }
  _nixKindCache[key] = kind;
  return kind;
}

/// POSIX single-quote escape: wraps [arg] in single quotes, escaping any
/// embedded single quote as `'\''`. Safe to pass through `sh -c` / `--run`.
String _posixSingleQuoteEscape(String arg) {
  return "'${arg.replaceAll("'", r"'\''")}'";
}

bool? _nixShellAvailableCache;
bool? _nixAvailableCache;

bool _whichExists(String binary) {
  try {
    final result = Process.runSync('which', [binary]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

bool _nixShellAvailable() =>
    _nixShellAvailableCache ??= _whichExists('nix-shell');
bool _nixAvailable() => _nixAvailableCache ??= _whichExists('nix');

/// The resolved command to execute for a given dart invocation.
///
/// If [error] is non-null the caller must return it directly without
/// executing anything.
class _ResolvedCommand {
  final String executable;
  final List<String> args;
  final _NixKind kind;
  final CallToolResult? error;
  _ResolvedCommand(
    this.executable,
    this.args,
    this.kind, {
    this.error,
  });

  String get display => '$executable ${args.join(' ')}';
}

/// Tracks per-project dirs we've already warned about to avoid log spam when
/// fallback mode is active.
final Set<String> _fallbackWarned = {};

/// Given the project [workingDir] and the requested dart [dartArgs],
/// return the concrete (executable, args) pair to spawn. When the project
/// declares a nix environment, the dart command is wrapped so the
/// project-pinned toolchain is used.
///
/// Behaviour when a required nix binary is missing on PATH:
/// - [allowFallback] = false (default): returns a `_ResolvedCommand` whose
///   [error] is a friendly JSON error telling the user to install Nix. The
///   caller should return that error directly without executing anything.
/// - [allowFallback] = true: logs a one-time warning per project and
///   falls back to running the system `dart` directly, unwrapped. Use this
///   when the operator explicitly opted in via `--allow-toolchain-fallback`
///   and accepts that the wrong SDK may be used.
///
/// Strategy (see task memory for rationale / timings):
/// - shell.nix → `nix-shell --run "<escaped dart ...>" shell.nix`
///   (impure — inherits PATH and reuses the cached nix store derivation,
///   so only the first invocation pays the shell-build cost).
/// - flake.nix → `nix develop --command dart <args>` (no escaping needed).
/// - otherwise → `dart <args>` unchanged.
_ResolvedCommand _getDartCommand(
  Directory projectRoot,
  List<String> dartArgs, {
  required bool allowFallback,
}) {
  final kind = _detectNixKind(projectRoot);
  switch (kind) {
    case _NixKind.none:
      return _ResolvedCommand('dart', dartArgs, kind);
    case _NixKind.shellNix:
      if (!_nixShellAvailable()) {
        return _handleMissingNixBinary(
          projectRoot: projectRoot,
          dartArgs: dartArgs,
          kind: kind,
          binary: 'nix-shell',
          declared: 'shell.nix',
          allowFallback: allowFallback,
        );
      }
      final runCmd =
          ['dart', ...dartArgs].map(_posixSingleQuoteEscape).join(' ');
      return _ResolvedCommand(
        'nix-shell',
        ['--run', runCmd, '${projectRoot.path}/shell.nix'],
        kind,
      );
    case _NixKind.flakeNix:
      if (!_nixAvailable()) {
        return _handleMissingNixBinary(
          projectRoot: projectRoot,
          dartArgs: dartArgs,
          kind: kind,
          binary: 'nix',
          declared: 'flake.nix',
          allowFallback: allowFallback,
        );
      }
      return _ResolvedCommand(
        'nix',
        ['develop', '--command', 'dart', ...dartArgs],
        kind,
      );
  }
}

_ResolvedCommand _handleMissingNixBinary({
  required Directory projectRoot,
  required List<String> dartArgs,
  required _NixKind kind,
  required String binary,
  required String declared,
  required bool allowFallback,
}) {
  if (allowFallback) {
    if (_fallbackWarned.add(projectRoot.path)) {
      logWarning(
        'dart-runner',
        "Project ${projectRoot.path} declares $declared but '$binary' is "
            "not on PATH. --allow-toolchain-fallback is set; falling back "
            "to the system dart. The pinned toolchain is NOT being used.",
      );
    }
    return _ResolvedCommand('dart', dartArgs, _NixKind.none);
  }
  return _ResolvedCommand(
    'dart',
    dartArgs,
    kind,
    error: textResult(jsonEncode({
      'status': 'error',
      'error': "Project declares $declared but the '$binary' binary was "
          "not found on PATH. Install Nix (https://nixos.org/download), "
          "remove $declared to use the system dart, or restart the server "
          "with --allow-toolchain-fallback to allow a warning-and-fallback "
          "to the system dart.",
    })),
  );
}



/// Start a long-running Dart command with progress notifications
Future<CallToolResult> _startDartCommandWithProgress(
  RequestHandlerExtra extra,
  Directory projectRoot,
  Directory workingDir,
  SessionManager sessionManager,
  String operation,
  List<String> dartArgs, {
  required bool allowFallback,
}) async {
  final cmd = _getDartCommand(projectRoot, dartArgs,
      allowFallback: allowFallback);
  if (cmd.error != null) return cmd.error!;

  final sessionId =
      sessionManager.createSession(operation, cmd.display);
  final session = sessionManager.getSession(sessionId)!;

  final outputStream = streamCommand(
    workingDir,
    cmd.executable,
    cmd.args,
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
  final response = <String, dynamic>{
    'status': 'completed',
    'session_id': sessionId,
    'operation': operation,
    'command': cmd.display,
    if (workingDir.path != projectRoot.path)
      'working_dir': workingDir.path,
    'output': allOutput.toString(),
  };

  return textResult(jsonEncode(response));
}


/// Run a short Dart command synchronously
Future<CallToolResult> _runDartCommandSync(
  Directory projectRoot,
  Directory workingDir,
  List<String> dartArgs, {
  required bool allowFallback,
}) async {
  final cmd = _getDartCommand(projectRoot, dartArgs,
      allowFallback: allowFallback);
  if (cmd.error != null) return cmd.error!;

  try {
    final result = await runCommand(workingDir, cmd.executable, cmd.args);

    final output = StringBuffer();
    output.writeln('Command: ${cmd.display}');
    if (workingDir.path != projectRoot.path) {
      output.writeln('Working directory: ${workingDir.path}');
    }
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
      'command': cmd.display,
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
