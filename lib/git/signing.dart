import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'package:dart_dev_mcp/dart_dev_mcp.dart';

import 'ssh_agent.dart';

/// Information about available signing methods for Git commits.
class SigningInfo {
  final bool sshAvailable;
  final String? sshKeyPath;
  final String? sshAgentSocket;
  final bool sshAgentHasKey;
  final bool gpgAvailable;
  final String? gpgKeyId;
  final String defaultMethod; // 'ssh', 'gpg', or 'none'
  final bool gitSupportsSSH; // Git 2.34+

  SigningInfo({
    required this.sshAvailable,
    this.sshKeyPath,
    this.sshAgentSocket,
    required this.sshAgentHasKey,
    required this.gpgAvailable,
    this.gpgKeyId,
    required this.defaultMethod,
    required this.gitSupportsSSH,
  });
}

/// Cached signing info
SigningInfo? _cachedSigningInfo;

/// Detect available signing capabilities.
///
/// Checks for SSH keys, SSH agent, GPG keys, and Git version.
/// Returns a [SigningInfo] object with the detected capabilities.
Future<SigningInfo> detectSigningCapabilities() async {
  if (_cachedSigningInfo != null) {
    return _cachedSigningInfo!;
  }

  // Check git version for SSH signing support (requires 2.34+)
  bool gitSupportsSSH = false;
  try {
    final gitVersion = await Process.run('git', ['--version']);
    if (gitVersion.exitCode == 0) {
      final versionStr = (gitVersion.stdout as String).trim();
      final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(versionStr);
      if (match != null) {
        final major = int.parse(match.group(1)!);
        final minor = int.parse(match.group(2)!);
        gitSupportsSSH = major > 2 || (major == 2 && minor >= 34);
      }
    }
  } catch (e) {
    // Git not available
  }

  // Find SSH agent
  final sshAgentSocket = await findSshAgentSocket();
  final sshAgentHasKey = await sshAgentHasIdentities(sshAgentSocket);

  // Check for SSH keys
  bool sshAvailable = false;
  String? sshKeyPath;
  final home = Platform.environment['HOME'];
  if (home != null && gitSupportsSSH) {
    final sshKeyPaths = [
      '$home/.ssh/id_ed25519.pub',
      '$home/.ssh/id_ecdsa.pub',
      '$home/.ssh/id_rsa.pub',
    ];

    for (final path in sshKeyPaths) {
      if (await File(path).exists()) {
        sshKeyPath = path;
        // SSH is only truly available if agent has the key loaded
        // (for passphrase-protected keys)
        sshAvailable = sshAgentHasKey || await _isKeyUnprotected(path);
        break;
      }
    }
  }

  // Check for GPG
  bool gpgAvailable = false;
  String? gpgKeyId;
  try {
    final gpgCheck =
        await Process.run('gpg', ['--list-secret-keys', '--keyid-format', 'LONG']);
    if (gpgCheck.exitCode == 0) {
      final output = gpgCheck.stdout as String;
      if (output.trim().isNotEmpty) {
        final match = RegExp(r'sec\s+\w+/([A-F0-9]+)').firstMatch(output);
        if (match != null) {
          gpgKeyId = match.group(1);
          gpgAvailable = true;
        }
      }
    }
  } catch (e) {
    // GPG not available
  }

  // Determine default method
  String defaultMethod;
  if (sshAvailable) {
    defaultMethod = 'ssh';
  } else if (gpgAvailable) {
    defaultMethod = 'gpg';
  } else {
    defaultMethod = 'none';
  }

  _cachedSigningInfo = SigningInfo(
    sshAvailable: sshAvailable,
    sshKeyPath: sshKeyPath,
    sshAgentSocket: sshAgentSocket,
    sshAgentHasKey: sshAgentHasKey,
    gpgAvailable: gpgAvailable,
    gpgKeyId: gpgKeyId,
    defaultMethod: defaultMethod,
    gitSupportsSSH: gitSupportsSSH,
  );

  return _cachedSigningInfo!;
}

/// Check if an SSH key is unprotected (no passphrase).
Future<bool> _isKeyUnprotected(String pubKeyPath) async {
  // The private key is the public key without .pub
  final privateKeyPath = pubKeyPath.endsWith('.pub')
      ? pubKeyPath.substring(0, pubKeyPath.length - 4)
      : pubKeyPath;

  try {
    // Try to load the key with empty passphrase
    final result = await Process.run(
      'ssh-keygen',
      ['-y', '-P', '', '-f', privateKeyPath],
    );
    return result.exitCode == 0;
  } catch (e) {
    return false;
  }
}

/// Get the SSH key path for signing.
Future<String?> getSSHKeyPath() async {
  final home = Platform.environment['HOME'];
  if (home == null) return null;

  final sshKeyPaths = [
    '$home/.ssh/id_ed25519.pub',
    '$home/.ssh/id_ecdsa.pub',
    '$home/.ssh/id_rsa.pub',
  ];

  for (final path in sshKeyPaths) {
    if (await File(path).exists()) {
      return path;
    }
  }

  return null;
}

/// Clear the cached signing info (useful for testing).
void clearSigningCache() {
  _cachedSigningInfo = null;
}

/// Check signing configuration and generate status report.
Future<CallToolResult> signingStatus(Directory workingDir, SigningInfo signingInfo) async {
  final output = StringBuffer();
  output.writeln('=== Commit Signing Status Report ===');
  output.writeln('');

  // 1. Git version and SSH signing support
  output.writeln('1. Git Version:');
  try {
    final gitVersion = await Process.run('git', ['--version']);
    if (gitVersion.exitCode == 0) {
      final versionStr = (gitVersion.stdout as String).trim();
      output.writeln('   $versionStr');
      output.writeln(
          '   SSH signing: ${signingInfo.gitSupportsSSH ? "✓ supported (2.34+)" : "✗ not supported (requires 2.34+)"}');
    }
  } catch (e) {
    output.writeln('   ✗ Git not available: $e');
  }
  output.writeln('');

  // 2. Default signing method
  output.writeln('2. Default Signing Method: ${signingInfo.defaultMethod.toUpperCase()}');
  output.writeln('   (Used when sign="auto")');
  output.writeln('');

  // 3. SSH Agent Status
  output.writeln('3. SSH Agent:');
  if (signingInfo.sshAgentSocket != null) {
    output.writeln('   ✓ Socket: ${signingInfo.sshAgentSocket}');

    final identities = await getSshAgentIdentities(signingInfo.sshAgentSocket);
    if (identities.isNotEmpty) {
      output.writeln('   ✓ Keys loaded: ${identities.length}');
      for (final identity in identities) {
        output.writeln('     - $identity');
      }
    } else {
      output.writeln('   ✗ No keys loaded in agent');
      output.writeln('   To add your key: ssh-add ~/.ssh/id_rsa');
    }
  } else {
    output.writeln('   ✗ SSH agent not found');
    output.writeln('   The SSH_AUTH_SOCK environment variable is not set.');
    if (Platform.isMacOS) {
      output.writeln('   On macOS, try: ssh-add --apple-use-keychain ~/.ssh/id_rsa');
    } else {
      output.writeln(r'   Start ssh-agent: eval $(ssh-agent) && ssh-add ~/.ssh/id_rsa');
    }
  }
  output.writeln('');

  // 4. SSH Keys
  output.writeln('4. SSH Keys:');
  final home = Platform.environment['HOME'] ?? '';
  final sshKeyPaths = [
    '$home/.ssh/id_ed25519.pub',
    '$home/.ssh/id_ecdsa.pub',
    '$home/.ssh/id_rsa.pub',
  ];

  bool foundSshKey = false;
  for (final path in sshKeyPaths) {
    final exists = await File(path).exists();
    final status = exists ? '✓' : '✗';
    if (exists && !foundSshKey) {
      output.writeln('   $status $path (will be used for signing)');
      foundSshKey = true;

      try {
        final fingerprint = await Process.run('ssh-keygen', ['-lf', path]);
        if (fingerprint.exitCode == 0) {
          output.writeln('     Fingerprint: ${(fingerprint.stdout as String).trim()}');
        }
      } catch (e) {
        // Ignore
      }

      // Check if key needs passphrase
      final isUnprotected = await _isKeyUnprotected(path);
      if (!isUnprotected) {
        output.writeln('     ⚠ Key is passphrase-protected (requires ssh-agent)');
      }
    } else {
      output.writeln('   $status $path');
    }
  }

  if (signingInfo.sshAvailable) {
    output.writeln('   Status: ✓ Ready for SSH signing');
  } else if (foundSshKey) {
    output.writeln('   Status: ⚠ Key found but not loaded in ssh-agent');
    output.writeln('   Run: ssh-add ~/.ssh/id_rsa');
  } else {
    output.writeln('   Status: ✗ No SSH key found');
    output.writeln('   To create: ssh-keygen -t ed25519 -C "your_email@example.com"');
  }
  output.writeln('');

  // 5. GPG Signing Status
  output.writeln('5. GPG Signing:');
  try {
    final gpgVersion = await Process.run('gpg', ['--version']);
    if (gpgVersion.exitCode == 0) {
      final firstLine = (gpgVersion.stdout as String).split('\n').first;
      output.writeln('   ✓ GPG installed: $firstLine');
    } else {
      output.writeln('   ✗ GPG not working: ${gpgVersion.stderr}');
    }
  } catch (e) {
    output.writeln('   ✗ GPG not found');
  }

  try {
    final keysResult = await Process.run(
      'gpg',
      ['--list-secret-keys', '--keyid-format', 'LONG'],
      environment: Platform.environment,
    );
    if (keysResult.exitCode == 0) {
      final keysOutput = keysResult.stdout as String;
      if (keysOutput.trim().isEmpty) {
        output.writeln('   ✗ No GPG secret keys found');
      } else {
        final keyMatches = RegExp(r'sec\s+').allMatches(keysOutput);
        output.writeln('   ✓ Found ${keyMatches.length} GPG secret key(s)');
      }
    }
  } catch (e) {
    // Already reported
  }

  if (signingInfo.gpgAvailable) {
    output.writeln('   Status: ✓ Ready for GPG signing');
  } else {
    output.writeln('   Status: ✗ GPG signing not available');
  }
  output.writeln('');

  // 6. Usage hints
  output.writeln('6. Usage:');
  output.writeln(
      '   commit with sign="auto"  - Uses ${signingInfo.defaultMethod.toUpperCase()} (auto-detected)');
  output.writeln('   commit with sign="ssh"   - Force SSH signing');
  output.writeln('   commit with sign="gpg"   - Force GPG signing');
  output.writeln('   commit with sign="none"  - No signing');
  output.writeln('');

  if (!signingInfo.sshAvailable && signingInfo.sshKeyPath != null) {
    output.writeln('⚠ IMPORTANT: Your SSH key is passphrase-protected.');
    output.writeln('  Before launching Claude Desktop, run:');
    output.writeln('    ssh-add ~/.ssh/id_rsa');
    output.writeln('  Then restart Claude Desktop to pick up the agent.');
    output.writeln('');
  }

  output.writeln('=== End of Signing Status Report ===');

  return textResult(output.toString());
}
