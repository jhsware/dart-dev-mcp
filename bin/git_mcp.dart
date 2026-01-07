import 'dart:io';

import 'package:git/git.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;

/// Git MCP Server
///
/// Provides Git operations for version control.
///
/// Usage: dart run bin/git_mcp.dart [project_path]
void main(List<String> arguments) async {
  // Determine working directory
  final projectPath =
      arguments.isNotEmpty ? arguments.first : Directory.current.path;
  final workingDir = Directory(p.normalize(p.absolute(projectPath)));

  if (!await workingDir.exists()) {
    stderr.writeln('Error: Project path does not exist: $projectPath');
    exit(1);
  }

  // Check if it's a git repository
  final isGitDir = await GitDir.isGitDir(workingDir.path);
  if (!isGitDir) {
    stderr.writeln('Warning: Not a git repository: $projectPath');
    stderr.writeln('Some operations may fail.');
  }

  stderr.writeln('Git MCP Server starting...');
  stderr.writeln('Project path: ${workingDir.path}');
  stderr.writeln('Is git repository: $isGitDir');

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
    description: '''Git version control operations.

Operations:
- status: Show working tree status
- branch-create: Create a new branch
- branch-list: List all branches
- branch-switch: Switch to a branch
- merge: Merge a branch into current branch
- add: Stage files for commit (supports untracked files, use all=true for all changes)
- commit: Commit staged changes
- stash: Stash current changes (use include_untracked=true for new files)
- stash-list: List all stashes
- stash-apply: Apply a stash
- stash-pop: Apply and remove a stash
- tag-create: Create a new tag
- tag-list: List all tags
- log: Show commit history
- diff: Show changes''',
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
    callback: ({args, extra}) => _handleGit(args, workingDir),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  stderr.writeln('Git MCP Server running on stdio');
}

CallToolResult _textResult(String text) {
  return CallToolResult.fromContent(
    content: [TextContent(text: text)],
  );
}

Future<CallToolResult> _handleGit(
  Map<String, dynamic>? args,
  Directory workingDir,
) async {
  final operation = args?['operation'] as String?;

  if (operation == null) {
    return _textResult('Error: operation is required');
  }

  // Verify it's a git directory for most operations
  if (operation != 'status') {
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
        return _add(workingDir, files, all: all);
      case 'commit':
        final message = args?['message'] as String?;
        return _commit(workingDir, message);
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

/// Run a git command and return the result
Future<ProcessResult> _runGit(
  Directory workingDir,
  List<String> args,
) async {
  return Process.run(
    'git',
    args,
    workingDirectory: workingDir.path,
  );
}

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

/// Stage files
Future<CallToolResult> _add(Directory workingDir, List<String>? files, {bool all = false}) async {
  List<String> gitArgs;
  
  if (all) {
    // Stage all changes including untracked files
    gitArgs = ['add', '--all', '--verbose'];
  } else if (files == null || files.isEmpty) {
    return _textResult(
        'Error: files is required. Use ["."] to stage all files, or set all=true to include untracked files.');
  } else {
    // Stage specific files (works for both tracked and untracked)
    gitArgs = ['add', '--verbose', ...files];
  }

  final result = await _runGit(workingDir, gitArgs);

  if (result.exitCode != 0) {
    return _textResult('Error staging files: ${result.stderr}');
  }

  final output = StringBuffer();
  
  // Verbose output goes to stderr for git add
  final verboseOutput = (result.stderr as String).trim();
  if (verboseOutput.isNotEmpty) {
    output.writeln(verboseOutput);
  }
  
  if (all) {
    output.writeln('Staged all changes (including untracked files)');
  } else {
    output.writeln('Staged files: ${files!.join(", ")}');
  }

  return _textResult(output.toString().trim());
}

/// Commit changes
Future<CallToolResult> _commit(Directory workingDir, String? message) async {
  if (message == null || message.isEmpty) {
    return _textResult('Error: commit message is required');
  }

  final result = await _runGit(workingDir, ['commit', '-m', message]);

  if (result.exitCode != 0) {
    final stderr = result.stderr as String;
    if (stderr.contains('nothing to commit')) {
      return _textResult('Nothing to commit. Stage changes with "add" first.');
    }
    return _textResult('Error committing: ${result.stderr}');
  }

  return _textResult('Committed: $message\n\n${result.stdout}');
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
  // Show both staged and unstaged changes
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
