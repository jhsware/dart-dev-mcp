import 'dart:io';

/// Git runner with GPG and SSH agent support.
///
/// Provides functions to run git commands with proper environment setup
/// for signing operations.

/// Cached GPG agent socket path
String? _gpgAgentSocket;

/// Find the GPG agent socket path.
Future<String?> findGpgAgentSocket() async {
  if (_gpgAgentSocket != null) {
    return _gpgAgentSocket;
  }

  try {
    final result =
        await Process.run('gpgconf', ['--list-dirs', 'agent-socket']);
    if (result.exitCode == 0) {
      final socket = (result.stdout as String).trim();
      if (socket.isNotEmpty && await File(socket).exists()) {
        _gpgAgentSocket = socket;
        return socket;
      }
    }
  } catch (e) {
    // gpgconf not available
  }

  final home = Platform.environment['HOME'];
  if (home != null) {
    final commonPaths = [
      '$home/.gnupg/S.gpg-agent',
      '/run/user/${Platform.environment['UID'] ?? '1000'}/gnupg/S.gpg-agent',
    ];

    for (final path in commonPaths) {
      if (await File(path).exists()) {
        _gpgAgentSocket = path;
        return path;
      }
    }
  }

  return null;
}

/// Ensure gpg-agent is running.
Future<bool> ensureGpgAgent() async {
  try {
    final result = await Process.run(
      'gpg-connect-agent',
      ['/bye'],
      environment: Platform.environment,
    );
    if (result.exitCode == 0) {
      return true;
    }
  } catch (e) {
    // Agent not running
  }

  try {
    final result = await Process.run(
      'gpgconf',
      ['--launch', 'gpg-agent'],
      environment: Platform.environment,
    );
    return result.exitCode == 0;
  } catch (e) {
    return false;
  }
}

/// Build environment for git commands.
Future<Map<String, String>> buildGitEnvironment({
  bool forGpgSign = false,
  bool forSshSign = false,
  String? sshAgentSocket,
}) async {
  final env = Map<String, String>.from(Platform.environment);

  // Always ensure SSH_AUTH_SOCK is set if we found an agent
  if (sshAgentSocket != null) {
    env['SSH_AUTH_SOCK'] = sshAgentSocket;
  }

  if (forGpgSign) {
    if (!env.containsKey('GPG_TTY') || env['GPG_TTY']!.isEmpty) {
      env['GPG_TTY'] = '/dev/tty';
    }

    if (!env.containsKey('GNUPGHOME')) {
      final home = env['HOME'];
      if (home != null) {
        final gnupgHome = '$home/.gnupg';
        if (await Directory(gnupgHome).exists()) {
          env['GNUPGHOME'] = gnupgHome;
        }
      }
    }

    final socket = await findGpgAgentSocket();
    if (socket != null && !env.containsKey('GPG_AGENT_INFO')) {
      env['GPG_AGENT_INFO'] = '$socket:0:1';
    }

    await ensureGpgAgent();
  }

  return env;
}

/// Run a git command and return the result.
Future<ProcessResult> runGit(
  Directory workingDir,
  List<String> args, {
  bool forGpgSign = false,
  bool forSshSign = false,
  String? sshAgentSocket,
}) async {
  final env = await buildGitEnvironment(
    forGpgSign: forGpgSign,
    forSshSign: forSshSign,
    sshAgentSocket: sshAgentSocket,
  );
  return Process.run(
    'git',
    args,
    workingDirectory: workingDir.path,
    environment: env,
  );
}

/// Clear the cached GPG agent socket (useful for testing).
void clearGpgAgentCache() {
  _gpgAgentSocket = null;
}
