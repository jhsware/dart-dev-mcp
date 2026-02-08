import 'dart:io';

/// SSH Agent support for Git operations.
///
/// Provides functions to find SSH agent sockets and check for loaded identities.

/// Cached SSH agent socket path
String? _cachedSshAgentSocket;

/// Find the SSH agent socket.
///
/// Checks in order:
/// 1. SSH_AUTH_SOCK environment variable
/// 2. macOS launchd socket
/// 3. Common Linux locations
Future<String?> findSshAgentSocket() async {
  if (_cachedSshAgentSocket != null) {
    return _cachedSshAgentSocket;
  }

  // 1. Check SSH_AUTH_SOCK environment variable
  final envSocket = Platform.environment['SSH_AUTH_SOCK'];
  if (envSocket != null && envSocket.isNotEmpty) {
    // Verify the socket exists
    final socketFile = File(envSocket);
    if (await socketFile.exists() ||
        await FileSystemEntity.type(envSocket) ==
            FileSystemEntityType.unixDomainSock) {
      _cachedSshAgentSocket = envSocket;
      return envSocket;
    }
  }

  // 2. macOS: Try launchd socket
  if (Platform.isMacOS) {
    try {
      final result =
          await Process.run('launchctl', ['getenv', 'SSH_AUTH_SOCK']);
      if (result.exitCode == 0) {
        final socket = (result.stdout as String).trim();
        if (socket.isNotEmpty && await socketExists(socket)) {
          _cachedSshAgentSocket = socket;
          return socket;
        }
      }
    } catch (e) {
      // launchctl not available
    }

    // Try common macOS locations
    final home = Platform.environment['HOME'];
    if (home != null) {
      // Check for actual socket files in launchd directories
      try {
        final tmpDir = Directory('/private/tmp');
        if (await tmpDir.exists()) {
          await for (final entity in tmpDir.list()) {
            if (entity is Directory &&
                entity.path.contains('com.apple.launchd')) {
              final listenersDir = Directory('${entity.path}/Listeners');
              if (await listenersDir.exists()) {
                await for (final listener in listenersDir.list()) {
                  if (await socketExists(listener.path)) {
                    _cachedSshAgentSocket = listener.path;
                    return listener.path;
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        // Ignore errors
      }
    }
  }

  // 3. Linux: Check common locations
  if (Platform.isLinux) {
    final uid = Platform.environment['UID'] ??
        Platform.environment['EUID'] ??
        '1000';
    final commonPaths = [
      '/run/user/$uid/ssh-agent.socket',
      '/run/user/$uid/keyring/ssh',
      '/tmp/ssh-agent-$uid/agent.sock',
    ];

    for (final path in commonPaths) {
      if (await socketExists(path)) {
        _cachedSshAgentSocket = path;
        return path;
      }
    }

    // Try to find ssh-agent sockets in /tmp
    try {
      final tmpDir = Directory('/tmp');
      await for (final entity in tmpDir.list()) {
        if (entity is Directory && entity.path.contains('ssh-')) {
          await for (final file in entity.list()) {
            if (file.path.contains('agent') && await socketExists(file.path)) {
              _cachedSshAgentSocket = file.path;
              return file.path;
            }
          }
        }
      }
    } catch (e) {
      // Ignore errors
    }
  }

  return null;
}

/// Check if a path is a socket (or at least exists).
Future<bool> socketExists(String path) async {
  try {
    final type = await FileSystemEntity.type(path);
    return type != FileSystemEntityType.notFound;
  } catch (e) {
    return false;
  }
}

/// Check if SSH agent has identities loaded.
Future<bool> sshAgentHasIdentities(String? socketPath) async {
  if (socketPath == null) return false;

  try {
    final result = await Process.run(
      'ssh-add',
      ['-l'],
      environment: {
        ...Platform.environment,
        'SSH_AUTH_SOCK': socketPath,
      },
    );
    // Exit code 0 = has identities, 1 = no identities, 2 = can't connect
    return result.exitCode == 0;
  } catch (e) {
    return false;
  }
}

/// Get list of identities from SSH agent.
Future<List<String>> getSshAgentIdentities(String? socketPath) async {
  if (socketPath == null) return [];

  try {
    final result = await Process.run(
      'ssh-add',
      ['-l'],
      environment: {
        ...Platform.environment,
        'SSH_AUTH_SOCK': socketPath,
      },
    );
    if (result.exitCode == 0) {
      return (result.stdout as String)
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
    }
  } catch (e) {
    // Ignore
  }
  return [];
}

/// Clear the cached SSH agent socket (useful for testing).
void clearSshAgentCache() {
  _cachedSshAgentSocket = null;
}
