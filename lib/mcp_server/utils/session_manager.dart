import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Represents an active session with cached output chunks
class ProcessSession {
  final String id;
  final String operation;
  final String description;
  final DateTime startedAt;
  final List<String> chunks = [];
  bool isComplete = false;
  int? exitCode;
  StreamSubscription<String>? _subscription;
  Process? _process;

  ProcessSession({
    required this.id,
    required this.operation,
    required this.description,
  }) : startedAt = DateTime.now();

  /// Starts collecting output from the stream
  void collectOutput(Stream<String> stream) {
    _subscription = stream.listen(
      (chunk) {
        chunks.add(chunk);
      },
      onDone: () {
        isComplete = true;
      },
      onError: (error) {
        chunks.add('ERROR: $error\n');
        isComplete = true;
      },
    );
  }

  /// Sets the process reference for potential cancellation
  void setProcess(Process process) {
    _process = process;
  }

  /// Cancel the subscription and kill the process if still active
  Future<void> cancel() async {
    await _subscription?.cancel();
    _process?.kill(ProcessSignal.sigterm);
    isComplete = true;
  }
}

/// Manages active process sessions
class SessionManager {
  static final SessionManager _instance = SessionManager._internal();
  factory SessionManager() => _instance;
  SessionManager._internal();

  final Map<String, ProcessSession> _sessions = {};
  int _sessionCounter = 0;

  /// Creates a new session and returns its ID
  String createSession(String operation, String description) {
    _sessionCounter++;
    final id =
        'session_${_sessionCounter}_${DateTime.now().millisecondsSinceEpoch}';
    final session = ProcessSession(
      id: id,
      operation: operation,
      description: description,
    );
    _sessions[id] = session;
    return id;
  }

  /// Gets a session by ID
  ProcessSession? getSession(String id) => _sessions[id];

  /// Removes a session
  Future<void> removeSession(String id) async {
    final session = _sessions[id];
    if (session != null) {
      await session.cancel();
      _sessions.remove(id);
    }
  }

  /// Lists all active sessions
  List<ProcessSession> get activeSessions =>
      _sessions.values.where((s) => !s.isComplete).toList();

  /// Lists all sessions
  List<ProcessSession> get allSessions => _sessions.values.toList();

  /// Cleans up completed sessions older than the specified duration
  void cleanupOldSessions({Duration maxAge = const Duration(hours: 1)}) {
    final now = DateTime.now();
    _sessions.removeWhere((id, session) {
      return session.isComplete && now.difference(session.startedAt) > maxAge;
    });
  }
}

/// Streams command output as it becomes available.
/// Each chunk is yielded as soon as it is received from the process.
Stream<String> streamCommand(
  Directory workingDir,
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  void Function(Process process)? onProcessStarted,
}) {
  final controller = StreamController<String>();

  Process.start(
    executable,
    arguments,
    workingDirectory: workingDir.path,
    runInShell: false,
    environment: environment,
  ).then((process) {
    // Notify caller of the process reference
    onProcessStarted?.call(process);

    var stdoutDone = false;
    var stderrDone = false;

    void checkClose() {
      if (stdoutDone && stderrDone) {
        process.exitCode.then((exitCode) {
          if (exitCode != 0) {
            controller.add('\n[Process exited with code: $exitCode]\n');
          } else {
            controller.add('\n[Process completed successfully]\n');
          }
          controller.close();
        });
      }
    }

    // Stream stdout
    process.stdout.transform(utf8.decoder).listen(
      (data) {
        controller.add(data);
      },
      onError: (error) {
        controller.add('STDOUT ERROR: $error\n');
      },
      onDone: () {
        stdoutDone = true;
        checkClose();
      },
    );

    // Stream stderr
    process.stderr.transform(utf8.decoder).listen(
      (data) {
        controller.add(data);
      },
      onError: (error) {
        controller.add('STDERR ERROR: $error\n');
      },
      onDone: () {
        stderrDone = true;
        checkClose();
      },
    );
  }).catchError((error) {
    controller.add('Failed to start process: $error\n');
    controller.close();
  });

  return controller.stream;
}

/// Runs a command and returns all output at once
Future<ProcessResult> runCommand(
  Directory workingDir,
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  return Process.run(
    executable,
    arguments,
    workingDirectory: workingDir.path,
    environment: environment,
  );
}
