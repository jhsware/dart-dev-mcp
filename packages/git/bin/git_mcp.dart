import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:git_mcp/git_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Git MCP Server
///
/// Provides Git operations for version control with path restrictions.
/// Supports SSH and GPG commit signing.
/// Allowed paths are resolved from jhsware-code.yaml per project.
///
/// Usage: `dart run bin/git_mcp.dart --project-dir=PATH1 [--project-dir=PATH2 ...]`
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

  // Detect available signing methods
  final signingInfo = await detectSigningCapabilities();

  logInfo('git', 'Git MCP Server starting...');
  logInfo('git', 'Project dirs: ${serverArgs.projectDirs.join(", ")}');
  logInfo('git',
      'Signing: ${signingInfo.defaultMethod} (SSH: ${signingInfo.sshAvailable ? "available" : "not available"}, GPG: ${signingInfo.gpgAvailable ? "available" : "not available"})');
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
        'project_dir': JsonSchema.string(
          description:
              'Project directory path. Must match one of the registered --project-dir values. REQUIRED for all operations.',
        ),
        'operation': JsonSchema.string(
          description: 'The git operation to perform',
          enumValues: _validOperations,
        ),
        'branch': JsonSchema.string(
          description:
              'Branch name (for branch-create, branch-switch, merge)',
        ),
        'from': JsonSchema.string(
          description:
              'Starting point for new branch (for branch-create). Default: current HEAD',
        ),
        'files': JsonSchema.array(
          items: JsonSchema.string(),
          description:
              'Files to stage (for add). Use ["."] for all files including untracked.',
        ),
        'all': JsonSchema.boolean(
          description:
              'Stage all changes including untracked files (for add). Default: false',
        ),
        'message': JsonSchema.string(
          description:
              'Commit or stash message (for commit, stash, tag-create)',
        ),
        'sign': JsonSchema.string(
          description:
              'Signing method for commit: "auto" (default - uses SSH if available, else GPG if available, else none), "ssh", "gpg", or "none"',
          enumValues: ['auto', 'ssh', 'gpg', 'none'],
        ),
        'stash_index': JsonSchema.integer(
          description:
              'Stash index to apply (for stash-apply, stash-pop). Default: 0 (latest)',
        ),
        'tag': JsonSchema.string(
          description: 'Tag name (for tag-create)',
        ),
        'annotated': JsonSchema.boolean(
          description:
              'Create an annotated tag with message (for tag-create). Default: false',
        ),
        'include_untracked': JsonSchema.boolean(
          description:
              'Include untracked files in stash (for stash). Default: false',
        ),
        'max_count': JsonSchema.integer(
          description:
              'Maximum number of commits to show (for log). Default: 10',
        ),
        'target': JsonSchema.string(
          description:
              'Target for diff comparison (for diff). Supports branch name (e.g. "main"), commit range (e.g. "main..feature"), or commit hash. When omitted, shows staged and unstaged changes.',
        ),
      },
      required: ['project_dir'],
    ),
    callback: (args, extra) =>
        _handleGit(args, serverArgs, signingInfo),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('git', 'Git MCP Server running on stdio');
}

void _printUsage() {
  stderr.writeln(
      'Usage: git_mcp --project-dir=PATH1 [--project-dir=PATH2 ...]');
  stderr.writeln('');
  stderr.writeln('Options:');
  stderr.writeln(
      '  --project-dir=PATH  Path to a project directory (required, can be repeated)');
  stderr.writeln('  --help, -h          Show this help message');
  stderr.writeln('');
  stderr.writeln(
      'Allowed paths are resolved from jhsware-code.yaml in each project directory.');
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
  Map<String, dynamic> args,
  ServerArguments serverArgs,
  SigningInfo signingInfo,
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

  // Auto-detect git repository root by walking up from projectDir
  final gitRoot = findGitRoot(projectDir!);

  // signing-status does not need a git repo
  if (gitRoot == null && operation != 'signing-status') {
    return validationError(
      'path',
      'No git repository found. Searched for a .git directory starting at '
      '"$projectDir" and walking up to the filesystem root without success. '
      'Run "git init" here or in a parent directory.',
    );
  }

  final workingDir = Directory(gitRoot ?? projectDir);
  final projectDirectory = Directory(projectDir);

  // Resolve allowed paths from ProjectConfigService
  final allowedPaths =
      ProjectConfigService.getAllowedPaths(projectDir, 'git');

  // Create operation handlers for this project
  final gitOps = GitOperations(
    workingDir: workingDir,
    projectDir: projectDirectory,
    allowedPaths: allowedPaths,
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
        return gitOps.branchCreate(
            args['branch'] as String?, args['from'] as String?);
      case 'branch-list':
        return gitOps.branchList();
      case 'branch-switch':
        return gitOps.branchSwitch(args['branch'] as String?);
      case 'merge':
        return gitOps.merge(args['branch'] as String?);
      case 'add':
        return gitOps.add(getFilesArg(args),
            all: args['all'] as bool? ?? false);
      case 'commit':
        return commitOps.commit(args['message'] as String?,
            sign: args['sign'] as String? ?? 'auto');
      case 'stash':
        return commitOps.stash(args['message'] as String?,
            includeUntracked:
                args['include_untracked'] as bool? ?? false);
      case 'stash-list':
        return commitOps.stashList();
      case 'stash-apply':
        return commitOps.stashApply(
            (args['stash_index'] as num?)?.toInt() ?? 0,
            pop: false);
      case 'stash-pop':
        return commitOps.stashApply(
            (args['stash_index'] as num?)?.toInt() ?? 0,
            pop: true);
      case 'tag-create':
        return gitOps.tagCreate(args['tag'] as String?,
            args['message'] as String?, args['annotated'] as bool? ?? false);
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
