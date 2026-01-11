import 'dart:io';

import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:git/git.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;

/// Git MCP Server
///
/// Provides Git operations for version control with path restrictions.
/// Supports SSH and GPG commit signing.
///
/// Usage: `dart run bin/git_mcp.dart --project-dir=PATH [allowed_paths...]`
void main(List<String> arguments) async {
  String? projectDir;
  final allowedPathArgs = <String>[];

  // Parse arguments
  for (final arg in arguments) {
    if (arg.startsWith('--project-dir=')) {
      projectDir = arg.substring('--project-dir='.length);
    } else if (arg == '--help' || arg == '-h') {
      _printUsage();
      exit(0);
    } else if (!arg.startsWith('-')) {
      allowedPathArgs.add(arg);
    }
  }

  // Validate required arguments
  if (projectDir == null || projectDir.isEmpty) {
    stderr.writeln('Error: --project-dir is required');
    stderr.writeln('');
    _printUsage();
    exit(1);
  }

  final workingDir = Directory(p.normalize(p.absolute(projectDir)));

  if (!await workingDir.exists()) {
    stderr.writeln('Error: Project path does not exist: $projectDir');
    exit(1);
  }

  // Convert allowed paths to absolute paths (default to project path if none specified)
  final List<String> allowedPaths;
  if (allowedPathArgs.isNotEmpty) {
    allowedPaths = allowedPathArgs.map((path) {
      if (p.isAbsolute(path)) {
        return p.normalize(path);
      } else {
        return p.normalize(p.join(workingDir.path, path));
      }
    }).toList();
  } else {
    // Default: allow entire project
    allowedPaths = [workingDir.path];
  }

  // Check if it's a git repository
  final isGitDir = await GitDir.isGitDir(workingDir.path);
  if (!isGitDir) {
    stderr.writeln('Warning: Not a git repository: $projectDir');
    stderr.writeln('Some operations may fail.');
  }

  // Detect available signing methods
  final signingInfo = await _detectSigningCapabilities();
  
  stderr.writeln('Git MCP Server starting...');
  stderr.writeln('Project path: ${workingDir.path}');
  stderr.writeln('Is git repository: $isGitDir');
  stderr.writeln('Signing: ${signingInfo.defaultMethod} (SSH: ${signingInfo.sshAvailable ? "available" : "not available"}, GPG: ${signingInfo.gpgAvailable ? "available" : "not available"})');
  if (signingInfo.sshAgentSocket != null) {
    stderr.writeln('SSH Agent: ${signingInfo.sshAgentSocket}');
  }
  stderr.writeln('Allowed paths:');
  for (final path in allowedPaths) {
    stderr.writeln('  - $path');
  }

  final server = McpServer(
    Implementation(name: 'git-mcp', version: '1.0.0'),
    options: ServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the git tool
  server.tool(
    'git',
    description: '''Git version control operations with SSH/GPG signing support.

Operations:
- status: Show working tree status
- branch-create: Create a new branch
- branch-list: List all branches
- branch-switch: Switch to a branch
- merge: Merge a branch into current branch
- add: Stage files for commit (supports untracked files, use all=true for all changes)
- commit: Commit staged changes (supports SSH and GPG signing)
- stash: Stash current changes (use include_untracked=true for new files)
- stash-list: List all stashes
- stash-apply: Apply a stash
- stash-pop: Apply and remove a stash
- tag-create: Create a new tag
- tag-list: List all tags
- log: Show commit history
- diff: Show changes
- signing-status: Check SSH/GPG signing configuration and status''',
    toolInputSchema: ToolInputSchema(
      properties: {
        'operation': {
          'type': 'string',
          'description': 'The git operation to perform',
          'enum': [
            'status',
            'branch-create',
            'branch-list',
            'branch-switch',
            'merge',
            'add',
            'commit',
            'stash',
            'stash-list',
            'stash-apply',
            'stash-pop',
            'tag-create',
            'tag-list',
            'log',
            'diff',
            'signing-status',
          ],
        },
        'branch': {
          'type': 'string',
          'description':
              'Branch name (for branch-create, branch-switch, merge)',
        },
        'from': {
          'type': 'string',
          'description':
              'Starting point for new branch (for branch-create). Default: current HEAD',
        },
        'files': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Files to stage (for add). Use ["."] for all files including untracked.',
        },
        'all': {
          'type': 'boolean',
          'description':
              'Stage all changes including untracked files (for add). Default: false',
        },
        'message': {
          'type': 'string',
          'description': 'Commit or stash message (for commit, stash, tag-create)',
        },
        'sign': {
          'type': 'string',
          'description':
              'Signing method for commit: "auto" (default - uses SSH if available, else GPG if available, else none), "ssh", "gpg", or "none"',
          'enum': ['auto', 'ssh', 'gpg', 'none'],
        },
        'stash_index': {
          'type': 'integer',
          'description':
              'Stash index to apply (for stash-apply, stash-pop). Default: 0 (latest)',
        },
        'tag': {
          'type': 'string',
          'description': 'Tag name (for tag-create)',
        },
        'annotated': {
          'type': 'boolean',
          'description':
              'Create an annotated tag with message (for tag-create). Default: false',
        },
        'include_untracked': {
          'type': 'boolean',
          'description':
              'Include untracked files in stash (for stash). Default: false',
        },
        'max_count': {
          'type': 'integer',
          'description': 'Maximum number of commits to show (for log). Default: 10',
        },
      },
    ),
    callback: ({args, extra}) =>
        _handleGit(args, workingDir, allowedPaths, signingInfo),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  stderr.writeln('Git MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln('Usage: git_mcp --project-dir=PATH [allowed_paths...]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln('  --project-dir=PATH  Path to the git repository (required)');
  stderr.writeln('  --help, -h          Show this help message');
  stderr.writeln('');
  stderr.writeln('Arguments:');
  stderr.writeln('  allowed_paths       Paths that can be staged (default: project_path)');
}




// =============================================================================
// SSH Agent Support
// =============================================================================

/// Cached SSH agent socket path
String? _cachedSshAgentSocket;

/// Find the SSH agent socket
/// 
/// Checks in order:
/// 1. SSH_AUTH_SOCK environment variable
/// 2. macOS launchd socket
/// 3. Common Linux locations
Future<String?> _findSshAgentSocket() async {
  if (_cachedSshAgentSocket != null) {
    return _cachedSshAgentSocket;
  }
  
  // 1. Check SSH_AUTH_SOCK environment variable
  final envSocket = Platform.environment['SSH_AUTH_SOCK'];
  if (envSocket != null && envSocket.isNotEmpty) {
    // Verify the socket exists
    final socketFile = File(envSocket);
    if (await socketFile.exists() || await FileSystemEntity.type(envSocket) == FileSystemEntityType.unixDomainSock) {
      _cachedSshAgentSocket = envSocket;
      return envSocket;
    }
  }
  
  // 2. macOS: Try launchd socket
  if (Platform.isMacOS) {
    try {
      final result = await Process.run('launchctl', ['getenv', 'SSH_AUTH_SOCK']);
      if (result.exitCode == 0) {
        final socket = (result.stdout as String).trim();
        if (socket.isNotEmpty && await _socketExists(socket)) {
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
            if (entity is Directory && entity.path.contains('com.apple.launchd')) {
              final listenersDir = Directory('${entity.path}/Listeners');
              if (await listenersDir.exists()) {
                await for (final listener in listenersDir.list()) {
                  if (await _socketExists(listener.path)) {
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
      if (await _socketExists(path)) {
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
            if (file.path.contains('agent') && await _socketExists(file.path)) {
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

/// Check if a path is a socket (or at least exists)
Future<bool> _socketExists(String path) async {
  try {
    final type = await FileSystemEntity.type(path);
    return type != FileSystemEntityType.notFound;
  } catch (e) {
    return false;
  }
}

/// Check if SSH agent has identities loaded
Future<bool> _sshAgentHasIdentities(String? socketPath) async {
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

/// Get list of identities from SSH agent
Future<List<String>> _getSshAgentIdentities(String? socketPath) async {
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

// =============================================================================
// Signing Detection and Configuration
// =============================================================================

/// Information about available signing methods
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

/// Detect available signing capabilities
Future<SigningInfo> _detectSigningCapabilities() async {
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
  final sshAgentSocket = await _findSshAgentSocket();
  final sshAgentHasKey = await _sshAgentHasIdentities(sshAgentSocket);

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
    final gpgCheck = await Process.run('gpg', ['--list-secret-keys', '--keyid-format', 'LONG']);
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

/// Check if an SSH key is unprotected (no passphrase)
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

/// Get the SSH key path for signing
Future<String?> _getSSHKeyPath() async {
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

// =============================================================================
// Main Handler
// =============================================================================

Future<CallToolResult> _handleGit(
  Map<String, dynamic>? args,
  Directory workingDir,
  List<String> allowedPaths,
  SigningInfo signingInfo,
) async {
  final operation = args?['operation'] as String?;

  if (operation == null) {
    return textResult('Error: operation is required');
  }

  // Verify it's a git directory for most operations
  if (operation != 'status' && operation != 'signing-status') {
    final isGitDir = await GitDir.isGitDir(workingDir.path);
    if (!isGitDir) {
      return textResult(
          'Error: ${workingDir.path} is not a git repository. Run "git init" first.');
    }
  }

  try {
    switch (operation) {
      case 'status':
        return _gitStatus(workingDir);
      case 'branch-create':
        final branch = args?['branch'] as String?;
        final from = args?['from'] as String?;
        return _branchCreate(workingDir, branch, from);
      case 'branch-list':
        return _branchList(workingDir);
      case 'branch-switch':
        final branch = args?['branch'] as String?;
        return _branchSwitch(workingDir, branch);
      case 'merge':
        final branch = args?['branch'] as String?;
        return _merge(workingDir, branch);
      case 'add':
        final files = _getFilesArg(args);
        final all = args?['all'] as bool? ?? false;
        return _add(workingDir, files, allowedPaths, all: all);
      case 'commit':
        final message = args?['message'] as String?;
        final sign = args?['sign'] as String? ?? 'auto';
        return _commit(workingDir, message, sign: sign, signingInfo: signingInfo);
      case 'stash':
        final message = args?['message'] as String?;
        final includeUntracked = args?['include_untracked'] as bool? ?? false;
        return _stash(workingDir, message, includeUntracked: includeUntracked);
      case 'stash-list':
        return _stashList(workingDir);
      case 'stash-apply':
        final index = (args?['stash_index'] as num?)?.toInt() ?? 0;
        return _stashApply(workingDir, index, pop: false);
      case 'stash-pop':
        final index = (args?['stash_index'] as num?)?.toInt() ?? 0;
        return _stashApply(workingDir, index, pop: true);
      case 'tag-create':
        final tag = args?['tag'] as String?;
        final message = args?['message'] as String?;
        final annotated = args?['annotated'] as bool? ?? false;
        return _tagCreate(workingDir, tag, message, annotated);
      case 'tag-list':
        return _tagList(workingDir);
      case 'log':
        final maxCount = (args?['max_count'] as num?)?.toInt() ?? 10;
        return _log(workingDir, maxCount);
      case 'diff':
        return _diff(workingDir);
      case 'signing-status':
        return _signingStatus(workingDir, signingInfo);
      default:
        return textResult('Error: Unknown operation: $operation');
    }
  } catch (e) {
    return textResult('Error: $e');
  }
}


List<String>? _getFilesArg(Map<String, dynamic>? args) {
  final files = args?['files'];
  if (files is List) {
    return files.cast<String>();
  }
  return null;
}

// =============================================================================
// GPG Support Functions
// =============================================================================

/// Cached GPG agent socket path
String? _gpgAgentSocket;

/// Find the GPG agent socket path
Future<String?> _findGpgAgentSocket() async {
  if (_gpgAgentSocket != null) {
    return _gpgAgentSocket;
  }
  
  try {
    final result = await Process.run('gpgconf', ['--list-dirs', 'agent-socket']);
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

/// Ensure gpg-agent is running
Future<bool> _ensureGpgAgent() async {
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

/// Build environment for git commands
Future<Map<String, String>> _buildGitEnvironment({
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
    
    final socket = await _findGpgAgentSocket();
    if (socket != null && !env.containsKey('GPG_AGENT_INFO')) {
      env['GPG_AGENT_INFO'] = '$socket:0:1';
    }
    
    await _ensureGpgAgent();
  }
  
  return env;
}

/// Run a git command and return the result
Future<ProcessResult> _runGit(
  Directory workingDir,
  List<String> args, {
  bool forGpgSign = false,
  bool forSshSign = false,
  String? sshAgentSocket,
}) async {
  final env = await _buildGitEnvironment(
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

// =============================================================================
// Git Operations
// =============================================================================

/// Get git status
Future<CallToolResult> _gitStatus(Directory workingDir) async {
  final isGitDir = await GitDir.isGitDir(workingDir.path);
  if (!isGitDir) {
    return textResult('Not a git repository: ${workingDir.path}');
  }

  final result = await _runGit(workingDir, ['status', '--short', '--branch']);

  if (result.exitCode != 0) {
    return textResult('Error: ${result.stderr}');
  }

  final output = result.stdout as String;
  if (output.trim().isEmpty) {
    return textResult('Nothing to commit, working tree clean');
  }

  return textResult(output);
}

/// Create a new branch
Future<CallToolResult> _branchCreate(
  Directory workingDir,
  String? branch,
  String? from,
) async {
  if (branch == null || branch.isEmpty) {
    return textResult('Error: branch name is required');
  }

  final args = ['branch', branch];
  if (from != null && from.isNotEmpty) {
    args.add(from);
  }

  final result = await _runGit(workingDir, args);

  if (result.exitCode != 0) {
    return textResult('Error creating branch: ${result.stderr}');
  }

  return textResult('Created branch: $branch');
}

/// List all branches
Future<CallToolResult> _branchList(Directory workingDir) async {
  final result = await _runGit(workingDir, ['branch', '-a', '-v']);

  if (result.exitCode != 0) {
    return textResult('Error: ${result.stderr}');
  }

  return textResult(result.stdout as String);
}

/// Switch to a branch
Future<CallToolResult> _branchSwitch(
  Directory workingDir,
  String? branch,
) async {
  if (branch == null || branch.isEmpty) {
    return textResult('Error: branch name is required');
  }

  final result = await _runGit(workingDir, ['checkout', branch]);

  if (result.exitCode != 0) {
    return textResult('Error switching branch: ${result.stderr}');
  }

  return textResult('Switched to branch: $branch');
}

/// Merge a branch (always creates a merge commit, never fast-forward or rebase)
/// 
/// This ensures proper merge history is maintained. If the current branch has
/// no commits yet, an empty initial commit is created first to enable a proper merge.
Future<CallToolResult> _merge(
  Directory workingDir,
  String? branch,
) async {
  if (branch == null || branch.isEmpty) {
    return textResult('Error: branch name is required');
  }

  // Check if current branch has any commits
  final hasCommits = await _branchHasCommits(workingDir);
  
  if (!hasCommits) {
    // Create an empty initial commit to enable proper merge
    // This ensures we get a real merge commit, not just moving the branch pointer
    final initResult = await _runGit(workingDir, [
      'commit', '--allow-empty', '-m', 'Initial commit (created for merge)'
    ]);
    
    if (initResult.exitCode != 0) {
      return textResult(
        'Error: Current branch has no commits and failed to create initial commit.\n'
        'Error: ${initResult.stderr}'
      );
    }
  }

  // Always use --no-ff to ensure a merge commit is created
  // This prevents fast-forward merges which would just move the branch pointer
  final args = ['merge', '--no-ff', branch];

  final result = await _runGit(workingDir, args);

  if (result.exitCode != 0) {
    final stderr = result.stderr as String;
    final stdout = result.stdout as String;
    
    if (stderr.contains('CONFLICT') || stdout.contains('CONFLICT')) {
      return textResult(
          'Merge conflict detected. Resolve conflicts and commit.\n\n$stdout\n$stderr');
    }
    
    // Handle case where branches have unrelated histories
    if (stderr.contains('refusing to merge unrelated histories')) {
      // Retry with --allow-unrelated-histories
      final retryArgs = ['merge', '--no-ff', '--allow-unrelated-histories', branch];
      final retryResult = await _runGit(workingDir, retryArgs);
      
      if (retryResult.exitCode != 0) {
        final retryStderr = retryResult.stderr as String;
        final retryStdout = retryResult.stdout as String;
        if (retryStderr.contains('CONFLICT') || retryStdout.contains('CONFLICT')) {
          return textResult(
              'Merge conflict detected. Resolve conflicts and commit.\n\n$retryStdout\n$retryStderr');
        }
        return textResult('Error merging: $retryStderr');
      }
      
      return textResult('Merged $branch into current branch (with unrelated histories)\n\n${retryResult.stdout}');
    }
    
    return textResult('Error merging: $stderr');
  }

  return textResult('Merged $branch into current branch\n\n${result.stdout}');
}

/// Check if the current branch has any commits
Future<bool> _branchHasCommits(Directory workingDir) async {
  final result = await _runGit(workingDir, ['rev-parse', 'HEAD']);
  return result.exitCode == 0;
}

/// Check if a path is within the allowed paths
bool _isAllowedPath(List<String> allowedPaths, String path) {
  final normalizedPath = p.normalize(path);
  
  return allowedPaths.any((String allowedRoot) {
    final normalizedRoot = p.normalize(allowedRoot);
    
    if (normalizedPath == normalizedRoot) {
      return true;
    }
    
    final rootWithSep = normalizedRoot.endsWith(p.separator) 
        ? normalizedRoot 
        : normalizedRoot + p.separator;
    
    return normalizedPath.startsWith(rootWithSep);
  });
}

/// Stage files
Future<CallToolResult> _add(
  Directory workingDir,
  List<String>? files,
  List<String> allowedPaths, {
  bool all = false,
}) async {
  if (all) {
    final statusResult = await _runGit(workingDir, ['status', '--porcelain']);
    if (statusResult.exitCode != 0) {
      return textResult('Error getting status: ${statusResult.stderr}');
    }

    final statusOutput = statusResult.stdout as String;
    if (statusOutput.trim().isEmpty) {
      return textResult('Nothing to stage');
    }

    final filesToAdd = <String>[];
    final deniedFiles = <String>[];
    
    for (final line in statusOutput.split('\n')) {
      if (line.length < 3) continue;
      
      var fileName = line.substring(3);
      
      if (fileName.contains(' -> ')) {
        fileName = fileName.split(' -> ').last;
      }
      
      if (fileName.startsWith('"') && fileName.endsWith('"')) {
        fileName = fileName.substring(1, fileName.length - 1);
      }
      
      final absPath = p.normalize(p.join(workingDir.path, fileName));
      
      if (_isAllowedPath(allowedPaths, absPath)) {
        filesToAdd.add(fileName);
      } else {
        deniedFiles.add(fileName);
      }
    }

    if (filesToAdd.isEmpty) {
      final msg = deniedFiles.isNotEmpty
          ? 'No files to stage. The following files are outside allowed paths:\n  ${deniedFiles.join('\n  ')}'
          : 'Nothing to stage';
      return textResult(msg);
    }

    final result = await _runGit(workingDir, ['add', '--verbose', ...filesToAdd]);

    if (result.exitCode != 0) {
      return textResult('Error staging files: ${result.stderr}');
    }

    final output = StringBuffer();
    final verboseOutput = (result.stderr as String).trim();
    if (verboseOutput.isNotEmpty) {
      output.writeln(verboseOutput);
    }
    output.writeln('Staged ${filesToAdd.length} file(s)');
    
    if (deniedFiles.isNotEmpty) {
      output.writeln('');
      output.writeln('Skipped (outside allowed paths):');
      for (final f in deniedFiles) {
        output.writeln('  - $f');
      }
    }

    return textResult(output.toString().trim());
  }
  
  if (files == null || files.isEmpty) {
    return textResult(
        'Error: files is required. Use ["."] to stage all allowed files, or set all=true.');
  }

  final filesToAdd = <String>[];
  final deniedFiles = <String>[];
  
  for (final file in files) {
    if (file == '.') {
      return _add(workingDir, null, allowedPaths, all: true);
    }
    
    final absPath = p.isAbsolute(file)
        ? p.normalize(file)
        : p.normalize(p.join(workingDir.path, file));
    
    if (_isAllowedPath(allowedPaths, absPath)) {
      filesToAdd.add(file);
    } else {
      deniedFiles.add(file);
    }
  }

  if (filesToAdd.isEmpty) {
    return textResult(
        'Error: None of the specified files are within allowed paths.\n'
        'Denied: ${deniedFiles.join(", ")}\n\n'
        'Allowed paths:\n  ${allowedPaths.join('\n  ')}');
  }

  final result = await _runGit(workingDir, ['add', '--verbose', ...filesToAdd]);

  if (result.exitCode != 0) {
    return textResult('Error staging files: ${result.stderr}');
  }

  final output = StringBuffer();
  final verboseOutput = (result.stderr as String).trim();
  if (verboseOutput.isNotEmpty) {
    output.writeln(verboseOutput);
  }
  output.writeln('Staged files: ${filesToAdd.join(", ")}');
  
  if (deniedFiles.isNotEmpty) {
    output.writeln('');
    output.writeln('Skipped (outside allowed paths): ${deniedFiles.join(", ")}');
  }

  return textResult(output.toString().trim());
}

/// Commit changes with optional signing
/// 
/// Sign parameter:
/// - 'auto': Use SSH if available, else GPG if available, else no signing
/// - 'ssh': Force SSH signing (requires SSH key)
/// - 'gpg': Force GPG signing (requires GPG key and agent)
/// - 'none': No signing
Future<CallToolResult> _commit(
  Directory workingDir,
  String? message, {
  required String sign,
  required SigningInfo signingInfo,
}) async {
  if (message == null || message.isEmpty) {
    return textResult('Error: commit message is required');
  }

  // Determine actual signing method
  String actualMethod;
  if (sign == 'auto') {
    actualMethod = signingInfo.defaultMethod;
  } else {
    actualMethod = sign;
  }

  // Validate requested method is available
  if (actualMethod == 'ssh') {
    if (signingInfo.sshKeyPath == null) {
      return textResult(
        'Error: SSH signing requested but no SSH key found.\n'
        'Expected key at: ~/.ssh/id_ed25519.pub, ~/.ssh/id_ecdsa.pub, or ~/.ssh/id_rsa.pub\n\n'
        'Use sign="none" to commit without signing, or sign="gpg" for GPG signing.'
      );
    }
    if (!signingInfo.sshAgentHasKey) {
      return textResult(
        'Error: SSH signing requires your key to be loaded in ssh-agent.\n\n'
        'Your key appears to be passphrase-protected. Before launching Claude, run:\n'
        '  ssh-add ~/.ssh/id_rsa\n\n'
        'Or use sign="none" to commit without signing.\n\n'
        'SSH Agent Socket: ${signingInfo.sshAgentSocket ?? "not found"}\n'
        'Keys in agent: ${signingInfo.sshAgentHasKey ? "yes" : "no"}'
      );
    }
  }
  if (actualMethod == 'gpg' && !signingInfo.gpgAvailable) {
    return textResult(
      'Error: GPG signing requested but no GPG key found.\n'
      'Run "gpg --list-secret-keys" to check your keys.\n\n'
      'Use sign="none" to commit without signing, or sign="ssh" for SSH signing.'
    );
  }

  final args = <String>['commit'];
  bool forGpgSign = false;
  bool forSshSign = false;
  
  switch (actualMethod) {
    case 'ssh':
      final sshKeyPath = signingInfo.sshKeyPath ?? await _getSSHKeyPath();
      if (sshKeyPath == null) {
        return textResult('Error: Could not find SSH key for signing');
      }
      
      args.insertAll(0, [
        '-c', 'gpg.format=ssh',
        '-c', 'user.signingkey=$sshKeyPath',
      ]);
      args.add('-S');
      forSshSign = true;
      break;
      
    case 'gpg':
      args.add('--gpg-sign');
      forGpgSign = true;
      break;
      
    case 'none':
    default:
      args.add('--no-gpg-sign');
      break;
  }
  
  args.addAll(['-m', message]);

  final result = await _runGit(
    workingDir, 
    args, 
    forGpgSign: forGpgSign,
    forSshSign: forSshSign,
    sshAgentSocket: signingInfo.sshAgentSocket,
  );

  if (result.exitCode != 0) {
    final stderr = result.stderr as String;
    if (stderr.contains('nothing to commit')) {
      return textResult('Nothing to commit. Stage changes with "add" first.');
    }
    
    // Provide helpful error messages for signing failures
    if (actualMethod == 'ssh') {
      if (stderr.contains('Load key') && stderr.contains('passphrase')) {
        return textResult(
          'Error: SSH key requires passphrase but ssh-agent is not available.\n\n'
          'Before launching Claude, run:\n'
          '  ssh-add ~/.ssh/id_rsa\n\n'
          'This will cache your passphrase in the SSH agent.\n'
          'Then restart Claude Desktop.\n\n'
          'Or use sign="none" to commit without signing.\n\n'
          'Original error: ${result.stderr}'
        );
      }
      if (stderr.contains('error: Load key') || stderr.contains('invalid format')) {
        return textResult(
          'Error: SSH signing failed - could not load key.\n'
          'Make sure your SSH key exists and is valid.\n\n'
          'Original error: ${result.stderr}'
        );
      }
    }
    
    if (actualMethod == 'gpg') {
      if (stderr.contains('secret key not available') || 
          stderr.contains('No secret key')) {
        return textResult(
          'Error: GPG signing failed - no secret key available.\n'
          'Make sure you have configured git with a valid signing key:\n'
          '  git config user.signingkey <KEY_ID>\n\n'
          'Original error: ${result.stderr}'
        );
      }
      if (stderr.contains('agent') || stderr.contains('socket')) {
        return textResult(
          'Error: GPG signing failed - cannot connect to gpg-agent.\n'
          'Make sure gpg-agent is running:\n'
          '  gpgconf --launch gpg-agent\n\n'
          'Or commit with sign="none" or sign="ssh".\n\n'
          'Original error: ${result.stderr}'
        );
      }
    }
    
    return textResult('Error committing: ${result.stderr}');
  }

  String signedNote;
  switch (actualMethod) {
    case 'ssh':
      signedNote = ' (SSH signed)';
      break;
    case 'gpg':
      signedNote = ' (GPG signed)';
      break;
    default:
      signedNote = '';
  }
  
  return textResult('Committed$signedNote: $message\n\n${result.stdout}');
}

/// Stash changes
Future<CallToolResult> _stash(Directory workingDir, String? message, {bool includeUntracked = false}) async {
  final args = ['stash', 'push'];
  
  if (includeUntracked) {
    args.add('--include-untracked');
  }
  
  if (message != null && message.isNotEmpty) {
    args.addAll(['-m', message]);
  }

  final result = await _runGit(workingDir, args);

  if (result.exitCode != 0) {
    return textResult('Error stashing: ${result.stderr}');
  }

  final output = result.stdout as String;
  if (output.contains('No local changes to save')) {
    return textResult('No changes to stash');
  }

  final untrackedNote = includeUntracked ? ' (including untracked files)' : '';
  return textResult('Stashed changes$untrackedNote${message != null ? ": $message" : ""}\n\n$output');
}

/// List stashes
Future<CallToolResult> _stashList(Directory workingDir) async {
  final result = await _runGit(workingDir, ['stash', 'list']);

  if (result.exitCode != 0) {
    return textResult('Error: ${result.stderr}');
  }

  final output = result.stdout as String;
  if (output.trim().isEmpty) {
    return textResult('No stashes');
  }

  return textResult(output);
}

/// Apply or pop a stash
Future<CallToolResult> _stashApply(
  Directory workingDir,
  int index,
  {required bool pop,}
) async {
  final command = pop ? 'pop' : 'apply';
  final result = await _runGit(workingDir, ['stash', command, 'stash@{$index}']);

  if (result.exitCode != 0) {
    return textResult('Error applying stash: ${result.stderr}');
  }

  final action = pop ? 'Popped' : 'Applied';
  return textResult('$action stash@{$index}\n\n${result.stdout}');
}

/// Create a tag
Future<CallToolResult> _tagCreate(
  Directory workingDir,
  String? tag,
  String? message,
  bool annotated,
) async {
  if (tag == null || tag.isEmpty) {
    return textResult('Error: tag name is required');
  }

  final args = ['tag'];
  
  if (annotated || (message != null && message.isNotEmpty)) {
    args.add('-a');
    args.add(tag);
    args.addAll(['-m', message ?? tag]);
  } else {
    args.add(tag);
  }

  final result = await _runGit(workingDir, args);

  if (result.exitCode != 0) {
    return textResult('Error creating tag: ${result.stderr}');
  }

  final tagType = annotated ? 'annotated tag' : 'tag';
  return textResult('Created $tagType: $tag');
}

/// List tags
Future<CallToolResult> _tagList(Directory workingDir) async {
  final result = await _runGit(workingDir, ['tag', '-l', '-n1']);

  if (result.exitCode != 0) {
    return textResult('Error: ${result.stderr}');
  }

  final output = result.stdout as String;
  if (output.trim().isEmpty) {
    return textResult('No tags');
  }

  return textResult(output);
}

/// Show commit log
Future<CallToolResult> _log(Directory workingDir, int maxCount) async {
  final result = await _runGit(workingDir, [
    'log',
    '--oneline',
    '--graph',
    '--decorate',
    '-n',
    maxCount.toString(),
  ]);

  if (result.exitCode != 0) {
    return textResult('Error: ${result.stderr}');
  }

  return textResult(result.stdout as String);
}

/// Show diff
Future<CallToolResult> _diff(Directory workingDir) async {
  final stagedResult = await _runGit(workingDir, ['diff', '--cached']);
  final unstagedResult = await _runGit(workingDir, ['diff']);

  final output = StringBuffer();

  final unstaged = unstagedResult.stdout as String;
  if (unstaged.isNotEmpty) {
    output.writeln('=== Unstaged changes ===');
    output.writeln(unstaged);
  }

  final staged = stagedResult.stdout as String;
  if (staged.isNotEmpty) {
    output.writeln('=== Staged changes ===');
    output.writeln(staged);
  }

  if (output.isEmpty) {
    return textResult('No changes');
  }

  return textResult(output.toString());
}


// =============================================================================
// Signing Status Report
// =============================================================================

/// Check signing configuration and status
Future<CallToolResult> _signingStatus(Directory workingDir, SigningInfo signingInfo) async {
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
      output.writeln('   SSH signing: ${signingInfo.gitSupportsSSH ? "✓ supported (2.34+)" : "✗ not supported (requires 2.34+)"}');
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
    
    final identities = await _getSshAgentIdentities(signingInfo.sshAgentSocket);
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
      output.writeln('   Start ssh-agent: eval \$(ssh-agent) && ssh-add ~/.ssh/id_rsa');
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
  output.writeln('   commit with sign="auto"  - Uses ${signingInfo.defaultMethod.toUpperCase()} (auto-detected)');
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
