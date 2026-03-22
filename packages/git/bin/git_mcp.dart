import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:git_mcp/git_mcp.dart';
import 'package:git/git.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;

/// Git MCP Server
///
/// Provides Git operations for version control with path restrictions.
/// Supports SSH and GPG commit signing.
///
/// Usage: `dart run bin/git_mcp.dart [--project-dir=PATH [allowed_paths...]]`
///
/// When project_root is passed as a tool call parameter, allowed paths are
/// read from jhsware-code.yaml in that project root. CLI args serve as fallback.
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

  // CLI-provided defaults (used as fallback when project_root not in tool call)
  Directory? cliWorkingDir;
  List<String> cliAllowedPaths = [];

  if (projectDir != null && projectDir.isNotEmpty) {
    cliWorkingDir = Directory(p.normalize(p.absolute(projectDir)));

    if (!await cliWorkingDir.exists()) {
      stderr.writeln('Error: Project path does not exist: $projectDir');
      exit(1);
    }

    // Convert allowed paths to absolute paths (default to project path if none specified)
    if (allowedPathArgs.isNotEmpty) {
      cliAllowedPaths = allowedPathArgs.map((path) {
        if (p.isAbsolute(path)) {
          return p.normalize(path);
        } else {
          return p.normalize(p.join(cliWorkingDir!.path, path));
        }
      }).toList();
    } else {
      // Default: allow entire project
      cliAllowedPaths = [cliWorkingDir.path];
    }
  }

  // Detect available signing methods
  final signingInfo = await detectSigningCapabilities();

  logInfo('git', 'Git MCP Server starting...');
  if (cliWorkingDir != null) {
    final isGitDir = await GitDir.isGitDir(cliWorkingDir.path);
    logInfo('git', 'CLI project path: ${cliWorkingDir.path}');
    logInfo('git', 'Is git repository: $isGitDir');
    logInfo('git', 'CLI allowed paths: ${cliAllowedPaths.join(", ")}');
  } else {
    logInfo('git', 'No CLI project directory set, project_root param required in tool calls');
  }
  logInfo('git', 'Signing: ${signingInfo.defaultMethod} (SSH: ${signingInfo.sshAvailable ? "available" : "not available"}, GPG: ${signingInfo.gpgAvailable ? "available" : "not available"})');
  if (signingInfo.sshAgentSocket != null) {
    logInfo('git', 'SSH Agent: ${signingInfo.sshAgentSocket}');
  }

  final server = McpServer(
    Implementation(name: 'git-mcp', version: '1.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the git tool
  server.registerTool(
    'git',
    description: '''Git version control operations with SSH/GPG signing support.

Operations:
- status: Show working tree status
- branch-create: Create a new branch and switch to it
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
- diff: Show changes (optionally compare branches/commits with target parameter)
- signing-status: Check SSH/GPG signing configuration and status''',
    inputSchema: ToolInputSchema(
      properties: {
        'operation': JsonSchema.string(
          description: 'The git operation to perform',
          enumValues: _validOperations,
        ),
        'branch': JsonSchema.string(
          description: 'Branch name (for branch-create, branch-switch, merge)',
        ),
        'from': JsonSchema.string(
          description: 'Starting point for new branch (for branch-create). Default: current HEAD',
        ),
        'files': JsonSchema.array(
          items: JsonSchema.string(),
          description: 'Files to stage (for add). Use ["."] for all files including untracked.',
        ),
        'all': JsonSchema.boolean(
          description: 'Stage all changes including untracked files (for add). Default: false',
        ),
        'message': JsonSchema.string(
          description: 'Commit or stash message (for commit, stash, tag-create)',
        ),
        'sign': JsonSchema.string(
          description: 'Signing method for commit: "auto" (default - uses SSH if available, else GPG if available, else none), "ssh", "gpg", or "none"',
          enumValues: ['auto', 'ssh', 'gpg', 'none'],
        ),
        'stash_index': JsonSchema.integer(
          description: 'Stash index to apply (for stash-apply, stash-pop). Default: 0 (latest)',
        ),
        'tag': JsonSchema.string(
          description: 'Tag name (for tag-create)',
        ),
        'annotated': JsonSchema.boolean(
          description: 'Create an annotated tag with message (for tag-create). Default: false',
        ),
        'include_untracked': JsonSchema.boolean(
          description: 'Include untracked files in stash (for stash). Default: false',
        ),
        'max_count': JsonSchema.integer(
          description: 'Maximum number of commits to show (for log). Default: 10',
        ),
        'target': JsonSchema.string(
          description: 'Target for diff comparison (for diff). Supports branch name (e.g. "main"), commit range (e.g. "main..feature"), or commit hash. When omitted, shows staged and unstaged changes.',
        ),
      },
    ),
    callback: (args, extra) => _handleGit(args, cliWorkingDir, cliAllowedPaths, signingInfo),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('git', 'Git MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln('Usage: git_mcp [--project-dir=PATH [allowed_paths...]]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln('  --project-dir=PATH  Path to the git repository (fallback)');
  stderr.writeln('  --help, -h          Show this help message');
  stderr.writeln('');
  stderr.writeln('Arguments:');
  stderr.writeln('  allowed_paths       Paths that can be staged (default: project_path)');
  stderr.writeln('');
  stderr.writeln('Note: When project_root is provided in a tool call, allowed paths');
  stderr.writeln('are read from jhsware-code.yaml in that project root instead.');
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

/// Resolve workingDir and allowedPaths from project_root parameter or CLI fallback.
({Directory workingDir, List<String> allowedPaths})? _resolveProjectContext(
  Map<String, dynamic> args,
  Directory? cliWorkingDir,
  List<String> cliAllowedPaths,
  String toolName,
) {
  final projectRoot = args['project_root'] as String?;

  if (projectRoot != null && projectRoot.isNotEmpty) {
    final absRoot = p.normalize(p.absolute(projectRoot));
    final workingDir = Directory(absRoot);
    final allowedPaths = ProjectConfigService.getAllowedPaths(absRoot, toolName);
    return (workingDir: workingDir, allowedPaths: allowedPaths);
  }

  if (cliWorkingDir != null) {
    return (workingDir: cliWorkingDir, allowedPaths: cliAllowedPaths);
  }

  return null;
}

Future<CallToolResult> _handleGit(
  Map<String, dynamic> args,
  Directory? cliWorkingDir,
  List<String> cliAllowedPaths,
  SigningInfo signingInfo,
) async {
  final operation = args['operation'] as String?;

  if (requireStringOneOf(operation, 'operation', _validOperations) case final error?) {
    return error;
  }

  // Resolve project context
  final context = _resolveProjectContext(args, cliWorkingDir, cliAllowedPaths, 'git');
  if (context == null) {
    return validationError('project_root',
        'No project_root provided and no CLI --project-dir configured. '
        'Either pass project_root in the tool call or start the server with --project-dir.');
  }

  final workingDir = context.workingDir;

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

  // Create operation handlers per invocation with resolved paths
  final gitOps = GitOperations(
    workingDir: workingDir,
    allowedPaths: context.allowedPaths,
  );

  final commitOps = CommitOperations(
    workingDir: workingDir,
    signingInfo: signingInfo,
  );

  try {
    switch (operation) {
      case 'status':
        return gitOps.status();
      case 'branch-create':
        return gitOps.branchCreate(args['branch'] as String?, args['from'] as String?);
      case 'branch-list':
        return gitOps.branchList();
      case 'branch-switch':
        return gitOps.branchSwitch(args['branch'] as String?);
      case 'merge':
        return gitOps.merge(args['branch'] as String?);
      case 'add':
        return gitOps.add(getFilesArg(args), all: args['all'] as bool? ?? false);
      case 'commit':
        return commitOps.commit(args['message'] as String?, sign: args['sign'] as String? ?? 'auto');
      case 'stash':
        return commitOps.stash(args['message'] as String?, includeUntracked: args['include_untracked'] as bool? ?? false);
      case 'stash-list':
        return commitOps.stashList();
      case 'stash-apply':
        return commitOps.stashApply((args['stash_index'] as num?)?.toInt() ?? 0, pop: false);
      case 'stash-pop':
        return commitOps.stashApply((args['stash_index'] as num?)?.toInt() ?? 0, pop: true);
      case 'tag-create':
        return gitOps.tagCreate(args['tag'] as String?, args['message'] as String?, args['annotated'] as bool? ?? false);
      case 'tag-list':
        return gitOps.tagList();
      case 'log':
        return gitOps.log((args['max_count'] as num?)?.toInt() ?? 10);
      case 'diff':
        return gitOps.diff(target: args['target'] as String?);
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
