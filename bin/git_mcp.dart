import 'dart:io';

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
        'no_ff': {
          'type': 'boolean',
          'description':
              'Create a merge commit even for fast-forward merges. Default: false',
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

CallToolResult _textResult(String text) {
  return CallToolResult.fromContent(
    content: [TextContent(text: text)],
  );
}

// =============================================================================
// Signing Detection and Configuration
// =============================================================================

/// Information about available signing methods
class SigningInfo {
  final bool sshAvailable;
  final String? sshKeyPath;
  final bool gpgAvailable;
  final String? gpgKeyId;
  final String defaultMethod; // 'ssh', 'gpg', or 'none'
  final bool gitSupportsSSH; // Git 2.34+

  SigningInfo({
    required this.sshAvailable,
    this.sshKeyPath,
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
      // Parse version like "git version 2.43.0"
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

  // Check for SSH keys
  bool sshAvailable = false;
  String? sshKeyPath;
  final home = Platform.environment['HOME'];
  if (home != null && gitSupportsSSH) {
    // Check common SSH key locations in order of preference
    final sshKeyPaths = [
      '$home/.ssh/id_ed25519.pub',
      '$home/.ssh/id_ecdsa.pub',
      '$home/.ssh/id_rsa.pub',
    ];
    
    for (final path in sshKeyPaths) {
      if (await File(path).exists()) {
        sshKeyPath = path;
        sshAvailable = true;
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
        // Extract first key ID
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

  // Determine default method: prefer SSH if available
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
    gpgAvailable: gpgAvailable,
    gpgKeyId: gpgKeyId,
    defaultMethod: defaultMethod,
    gitSupportsSSH: gitSupportsSSH,
  );

  return _cachedSigningInfo!;
}

/// Get the SSH key path for signing
Future<String?> _getSSHKeyPath() async {
  final home = Platform.environment['HOME'];
  if (home == null) return null;

  // Check common SSH key locations in order of preference
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
    return _textResult('Error: operation is required');
  }

  // Verify it's a git directory for most operations
  if (operation != 'status' && operation != 'signing-status') {
    final isGitDir = await GitDir.isGitDir(workingDir.path);
    if (!isGitDir) {
      return _textResult(
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
        final noFf = args?['no_ff'] as bool? ?? false;
        return _merge(workingDir, branch, noFf);
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
        return _textResult('Error: Unknown operation: $operation');
    }
  } catch (e) {
    return _textResult('Error: $e');
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
Future<Map<String, String>> _buildGitEnvironment({bool forGpgSign = false}) async {
  final env = Map<String, String>.from(Platform.environment);
  
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
}) async {
  final env = await _buildGitEnvironment(forGpgSign: forGpgSign);
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
    return _textResult('Not a git repository: ${workingDir.path}');
  }

  final result = await _runGit(workingDir, ['status', '--short', '--branch']);

  if (result.exitCode != 0) {
    return _textResult('Error: ${result.stderr}');
  }

  final output = result.stdout as String;
  if (output.trim().isEmpty) {
    return _textResult('Nothing to commit, working tree clean');
  }

  return _textResult(output);
}

/// Create a new branch
Future<CallToolResult> _branchCreate(
  Directory workingDir,
  String? branch,
  String? from,
) async {
  if (branch == null || branch.isEmpty) {
    return _textResult('Error: branch name is required');
  }

  final args = ['branch', branch];
  if (from != null && from.isNotEmpty) {
    args.add(from);
  }

  final result = await _runGit(workingDir, args);

  if (result.exitCode != 0) {
    return _textResult('Error creating branch: ${result.stderr}');
  }

  return _textResult('Created branch: $branch');
}

/// List all branches
Future<CallToolResult> _branchList(Directory workingDir) async {
  final result = await _runGit(workingDir, ['branch', '-a', '-v']);

  if (result.exitCode != 0) {
    return _textResult('Error: ${result.stderr}');
  }

  return _textResult(result.stdout as String);
}

/// Switch to a branch
Future<CallToolResult> _branchSwitch(
  Directory workingDir,
  String? branch,
) async {
  if (branch == null || branch.isEmpty) {
    return _textResult('Error: branch name is required');
  }

  final result = await _runGit(workingDir, ['checkout', branch]);

  if (result.exitCode != 0) {
    return _textResult('Error switching branch: ${result.stderr}');
  }

  return _textResult('Switched to branch: $branch');
}

/// Merge a branch
Future<CallToolResult> _merge(
  Directory workingDir,
  String? branch,
  bool noFf,
) async {
  if (branch == null || branch.isEmpty) {
    return _textResult('Error: branch name is required');
  }

  final args = ['merge'];
  if (noFf) {
    args.add('--no-ff');
  }
  args.add(branch);

  final result = await _runGit(workingDir, args);

  if (result.exitCode != 0) {
    final stderr = result.stderr as String;
    if (stderr.contains('CONFLICT')) {
      return _textResult(
          'Merge conflict detected. Resolve conflicts and commit.\n\n${result.stdout}\n${result.stderr}');
    }
    return _textResult('Error merging: ${result.stderr}');
  }

  return _textResult('Merged $branch into current branch\n\n${result.stdout}');
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
      return _textResult('Error getting status: ${statusResult.stderr}');
    }

    final statusOutput = statusResult.stdout as String;
    if (statusOutput.trim().isEmpty) {
      return _textResult('Nothing to stage');
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
      return _textResult(msg);
    }

    final result = await _runGit(workingDir, ['add', '--verbose', ...filesToAdd]);

    if (result.exitCode != 0) {
      return _textResult('Error staging files: ${result.stderr}');
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

    return _textResult(output.toString().trim());
  }
  
  if (files == null || files.isEmpty) {
    return _textResult(
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
    return _textResult(
        'Error: None of the specified files are within allowed paths.\n'
        'Denied: ${deniedFiles.join(", ")}\n\n'
        'Allowed paths:\n  ${allowedPaths.join('\n  ')}');
  }

  final result = await _runGit(workingDir, ['add', '--verbose', ...filesToAdd]);

  if (result.exitCode != 0) {
    return _textResult('Error staging files: ${result.stderr}');
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

  return _textResult(output.toString().trim());
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
    return _textResult('Error: commit message is required');
  }

  // Determine actual signing method
  String actualMethod;
  if (sign == 'auto') {
    actualMethod = signingInfo.defaultMethod;
  } else {
    actualMethod = sign;
  }

  // Validate requested method is available
  if (actualMethod == 'ssh' && !signingInfo.sshAvailable) {
    return _textResult(
      'Error: SSH signing requested but no SSH key found.\n'
      'Expected key at: ~/.ssh/id_ed25519.pub, ~/.ssh/id_ecdsa.pub, or ~/.ssh/id_rsa.pub\n\n'
      'Use sign="none" to commit without signing, or sign="gpg" for GPG signing.'
    );
  }
  if (actualMethod == 'gpg' && !signingInfo.gpgAvailable) {
    return _textResult(
      'Error: GPG signing requested but no GPG key found.\n'
      'Run "gpg --list-secret-keys" to check your keys.\n\n'
      'Use sign="none" to commit without signing, or sign="ssh" for SSH signing.'
    );
  }

  final args = <String>['commit'];
  bool forGpgSign = false;
  
  switch (actualMethod) {
    case 'ssh':
      // For SSH signing, we need to configure git temporarily
      final sshKeyPath = signingInfo.sshKeyPath ?? await _getSSHKeyPath();
      if (sshKeyPath == null) {
        return _textResult('Error: Could not find SSH key for signing');
      }
      
      // Set up SSH signing with -c options
      args.insertAll(0, [
        '-c', 'gpg.format=ssh',
        '-c', 'user.signingkey=$sshKeyPath',
      ]);
      args.add('-S'); // Sign the commit
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

  final result = await _runGit(workingDir, args, forGpgSign: forGpgSign);

  if (result.exitCode != 0) {
    final stderr = result.stderr as String;
    if (stderr.contains('nothing to commit')) {
      return _textResult('Nothing to commit. Stage changes with "add" first.');
    }
    
    // Provide helpful error messages for signing failures
    if (actualMethod == 'ssh') {
      if (stderr.contains('error: Load key') || stderr.contains('invalid format')) {
        return _textResult(
          'Error: SSH signing failed - could not load key.\n'
          'Make sure your SSH key exists and is valid.\n\n'
          'Original error: ${result.stderr}'
        );
      }
    }
    
    if (actualMethod == 'gpg') {
      if (stderr.contains('secret key not available') || 
          stderr.contains('No secret key')) {
        return _textResult(
          'Error: GPG signing failed - no secret key available.\n'
          'Make sure you have configured git with a valid signing key:\n'
          '  git config user.signingkey <KEY_ID>\n\n'
          'Original error: ${result.stderr}'
        );
      }
      if (stderr.contains('agent') || stderr.contains('socket')) {
        return _textResult(
          'Error: GPG signing failed - cannot connect to gpg-agent.\n'
          'Make sure gpg-agent is running:\n'
          '  gpgconf --launch gpg-agent\n\n'
          'Or commit with sign="none" or sign="ssh".\n\n'
          'Original error: ${result.stderr}'
        );
      }
    }
    
    return _textResult('Error committing: ${result.stderr}');
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
  
  return _textResult('Committed$signedNote: $message\n\n${result.stdout}');
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
    return _textResult('Error stashing: ${result.stderr}');
  }

  final output = result.stdout as String;
  if (output.contains('No local changes to save')) {
    return _textResult('No changes to stash');
  }

  final untrackedNote = includeUntracked ? ' (including untracked files)' : '';
  return _textResult('Stashed changes$untrackedNote${message != null ? ": $message" : ""}\n\n$output');
}

/// List stashes
Future<CallToolResult> _stashList(Directory workingDir) async {
  final result = await _runGit(workingDir, ['stash', 'list']);

  if (result.exitCode != 0) {
    return _textResult('Error: ${result.stderr}');
  }

  final output = result.stdout as String;
  if (output.trim().isEmpty) {
    return _textResult('No stashes');
  }

  return _textResult(output);
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
    return _textResult('Error applying stash: ${result.stderr}');
  }

  final action = pop ? 'Popped' : 'Applied';
  return _textResult('$action stash@{$index}\n\n${result.stdout}');
}

/// Create a tag
Future<CallToolResult> _tagCreate(
  Directory workingDir,
  String? tag,
  String? message,
  bool annotated,
) async {
  if (tag == null || tag.isEmpty) {
    return _textResult('Error: tag name is required');
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
    return _textResult('Error creating tag: ${result.stderr}');
  }

  final tagType = annotated ? 'annotated tag' : 'tag';
  return _textResult('Created $tagType: $tag');
}

/// List tags
Future<CallToolResult> _tagList(Directory workingDir) async {
  final result = await _runGit(workingDir, ['tag', '-l', '-n1']);

  if (result.exitCode != 0) {
    return _textResult('Error: ${result.stderr}');
  }

  final output = result.stdout as String;
  if (output.trim().isEmpty) {
    return _textResult('No tags');
  }

  return _textResult(output);
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
    return _textResult('Error: ${result.stderr}');
  }

  return _textResult(result.stdout as String);
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
    return _textResult('No changes');
  }

  return _textResult(output.toString());
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
  
  // 3. SSH Signing Status
  output.writeln('3. SSH Signing:');
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
      
      // Show key fingerprint
      try {
        final fingerprint = await Process.run('ssh-keygen', ['-lf', path]);
        if (fingerprint.exitCode == 0) {
          output.writeln('     Fingerprint: ${(fingerprint.stdout as String).trim()}');
        }
      } catch (e) {
        // Ignore
      }
    } else {
      output.writeln('   $status $path');
    }
  }
  
  if (signingInfo.sshAvailable) {
    output.writeln('   Status: ✓ Ready for SSH signing');
  } else {
    output.writeln('   Status: ✗ No SSH key found');
    output.writeln('   To enable: ssh-keygen -t ed25519 -C "your_email@example.com"');
  }
  output.writeln('');
  
  // 4. GPG Signing Status
  output.writeln('4. GPG Signing:');
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
  
  // Check GPG keys
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
        
        final lines = keysOutput.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('sec ')) {
            final keyMatch = RegExp(r'sec\s+\w+/([A-F0-9]+)').firstMatch(lines[i]);
            if (keyMatch != null) {
              output.writeln('   - Key ID: ${keyMatch.group(1)}');
            }
            for (var j = i + 1; j < lines.length && j < i + 5; j++) {
              if (lines[j].contains('uid ')) {
                output.writeln('     ${lines[j].trim()}');
                break;
              }
            }
          }
        }
      }
    }
  } catch (e) {
    // Already reported GPG not found
  }
  
  // Check GPG agent
  try {
    final agentCheck = await Process.run(
      'gpg-connect-agent',
      ['/bye'],
      environment: Platform.environment,
    );
    if (agentCheck.exitCode == 0) {
      output.writeln('   ✓ GPG agent is running');
    } else {
      output.writeln('   ? GPG agent not responding (may need: gpgconf --launch gpg-agent)');
    }
  } catch (e) {
    output.writeln('   ? Could not check GPG agent');
  }
  
  if (signingInfo.gpgAvailable) {
    output.writeln('   Status: ✓ Ready for GPG signing');
  } else {
    output.writeln('   Status: ✗ GPG signing not available');
  }
  output.writeln('');
  
  // 5. Git configuration
  output.writeln('5. Git Signing Configuration:');
  
  final gpgFormat = await _runGit(workingDir, ['config', '--get', 'gpg.format']);
  output.writeln('   gpg.format: ${gpgFormat.exitCode == 0 ? (gpgFormat.stdout as String).trim() : '(not set, default: openpgp)'}');
  
  final signingKey = await _runGit(workingDir, ['config', '--get', 'user.signingkey']);
  output.writeln('   user.signingkey: ${signingKey.exitCode == 0 ? (signingKey.stdout as String).trim() : '(not set)'}');
  
  final commitSign = await _runGit(workingDir, ['config', '--get', 'commit.gpgsign']);
  output.writeln('   commit.gpgsign: ${commitSign.exitCode == 0 ? (commitSign.stdout as String).trim() : 'false (default)'}');
  
  final gpgProgram = await _runGit(workingDir, ['config', '--get', 'gpg.program']);
  if (gpgProgram.exitCode == 0) {
    output.writeln('   gpg.program: ${(gpgProgram.stdout as String).trim()}');
  }
  
  final sshProgram = await _runGit(workingDir, ['config', '--get', 'gpg.ssh.program']);
  if (sshProgram.exitCode == 0) {
    output.writeln('   gpg.ssh.program: ${(sshProgram.stdout as String).trim()}');
  }
  output.writeln('');
  
  // 6. Usage hints
  output.writeln('6. Usage:');
  output.writeln('   commit with sign="auto"  - Uses ${signingInfo.defaultMethod.toUpperCase()} (auto-detected)');
  output.writeln('   commit with sign="ssh"   - Force SSH signing');
  output.writeln('   commit with sign="gpg"   - Force GPG signing');
  output.writeln('   commit with sign="none"  - No signing');
  output.writeln('');
  
  output.writeln('=== End of Signing Status Report ===');
  
  return _textResult(output.toString());
}
