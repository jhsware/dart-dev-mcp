import 'dart:io';

import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:dart_dev_mcp/git/git.dart';
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
    logWarning('git', 'Not a git repository: $projectDir. Some operations may fail.');
  }

  // Detect available signing methods
  final signingInfo = await detectSigningCapabilities();

  logInfo('git', 'Git MCP Server starting...');
  logInfo('git', 'Project path: ${workingDir.path}');
  logInfo('git', 'Is git repository: $isGitDir');
  logInfo('git', 'Signing: ${signingInfo.defaultMethod} (SSH: ${signingInfo.sshAvailable ? "available" : "not available"}, GPG: ${signingInfo.gpgAvailable ? "available" : "not available"})');
  if (signingInfo.sshAgentSocket != null) {
    logInfo('git', 'SSH Agent: ${signingInfo.sshAgentSocket}');
  }
  logInfo('git', 'Allowed paths: ${allowedPaths.join(", ")}');

  // Create git operations handler
  final gitOps = GitOperations(
    workingDir: workingDir,
    allowedPaths: allowedPaths,
    signingInfo: signingInfo,
  );

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
          'enum': _validOperations,
        },
        'branch': {
          'type': 'string',
          'description': 'Branch name (for branch-create, branch-switch, merge)',
        },
        'from': {
          'type': 'string',
          'description': 'Starting point for new branch (for branch-create). Default: current HEAD',
        },
        'files': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Files to stage (for add). Use ["."] for all files including untracked.',
        },
        'all': {
          'type': 'boolean',
          'description': 'Stage all changes including untracked files (for add). Default: false',
        },
        'message': {
          'type': 'string',
          'description': 'Commit or stash message (for commit, stash, tag-create)',
        },
        'sign': {
          'type': 'string',
          'description': 'Signing method for commit: "auto" (default - uses SSH if available, else GPG if available, else none), "ssh", "gpg", or "none"',
          'enum': ['auto', 'ssh', 'gpg', 'none'],
        },
        'stash_index': {
          'type': 'integer',
          'description': 'Stash index to apply (for stash-apply, stash-pop). Default: 0 (latest)',
        },
        'tag': {
          'type': 'string',
          'description': 'Tag name (for tag-create)',
        },
        'annotated': {
          'type': 'boolean',
          'description': 'Create an annotated tag with message (for tag-create). Default: false',
        },
        'include_untracked': {
          'type': 'boolean',
          'description': 'Include untracked files in stash (for stash). Default: false',
        },
        'max_count': {
          'type': 'integer',
          'description': 'Maximum number of commits to show (for log). Default: 10',
        },
      },
    ),
    callback: ({args, extra}) => _handleGit(args, gitOps, workingDir, signingInfo),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('git', 'Git MCP Server running on stdio');
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

const _validOperations = [
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
];

Future<CallToolResult> _handleGit(
  Map<String, dynamic>? args,
  GitOperations gitOps,
  Directory workingDir,
  SigningInfo signingInfo,
) async {
  final operation = args?['operation'] as String?;

  if (requireStringOneOf(operation, 'operation', _validOperations) case final error?) {
    return error;
  }

  // Verify it's a git directory for most operations
  if (operation != 'status' && operation != 'signing-status') {
    final isGitDir = await GitDir.isGitDir(workingDir.path);
    if (!isGitDir) {
      return validationError(
        'path',
        '${workingDir.path} is not a git repository. Run "git init" first.',
      );
    }
  }

  try {
    switch (operation) {
      case 'status':
        return gitOps.status();
      case 'branch-create':
        return gitOps.branchCreate(args?['branch'] as String?, args?['from'] as String?);
      case 'branch-list':
        return gitOps.branchList();
      case 'branch-switch':
        return gitOps.branchSwitch(args?['branch'] as String?);
      case 'merge':
        return gitOps.merge(args?['branch'] as String?);
      case 'add':
        return gitOps.add(getFilesArg(args), all: args?['all'] as bool? ?? false);
      case 'commit':
        return gitOps.commit(args?['message'] as String?, sign: args?['sign'] as String? ?? 'auto');
      case 'stash':
        return gitOps.stash(args?['message'] as String?, includeUntracked: args?['include_untracked'] as bool? ?? false);
      case 'stash-list':
        return gitOps.stashList();
      case 'stash-apply':
        return gitOps.stashApply((args?['stash_index'] as num?)?.toInt() ?? 0, pop: false);
      case 'stash-pop':
        return gitOps.stashApply((args?['stash_index'] as num?)?.toInt() ?? 0, pop: true);
      case 'tag-create':
        return gitOps.tagCreate(args?['tag'] as String?, args?['message'] as String?, args?['annotated'] as bool? ?? false);
      case 'tag-list':
        return gitOps.tagList();
      case 'log':
        return gitOps.log((args?['max_count'] as num?)?.toInt() ?? 10);
      case 'diff':
        return gitOps.diff();
      case 'signing-status':
        return signingStatus(workingDir, signingInfo);
      default:
        return validationError('operation', 'Unknown operation: $operation');
    }
  } catch (e, stackTrace) {
    return errorResult('git:$operation', e, stackTrace, {
      'operation': operation,
    });
  }
}
