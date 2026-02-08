import 'dart:io';

import 'package:git/git.dart' hide runGit;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;

import 'package:jhsware_code_shared_libs/shared_libs.dart';

import 'git_runner.dart';
import 'signing.dart';


/// Git operations handler.
///
/// Provides all git operations as methods returning [CallToolResult].
class GitOperations {
  final Directory workingDir;
  final List<String> allowedPaths;
  final SigningInfo signingInfo;

  GitOperations({
    required this.workingDir,
    required this.allowedPaths,
    required this.signingInfo,
  });

  /// Get git status.
  Future<CallToolResult> status() async {
    final isGitDir = await GitDir.isGitDir(workingDir.path);
    if (!isGitDir) {
      return textResult('Not a git repository: ${workingDir.path}');
    }

    final result = await runGit(workingDir, ['status', '--short', '--branch']);

    if (result.exitCode != 0) {
      return textResult('Error: ${result.stderr}');
    }

    final output = result.stdout as String;
    if (output.trim().isEmpty) {
      return textResult('Nothing to commit, working tree clean');
    }

    return textResult(output);
  }

  /// Create a new branch.
  Future<CallToolResult> branchCreate(String? branch, String? from) async {
    if (requireString(branch, 'branch') case final error?) {
      return error;
    }

    final args = ['branch', branch!];
    if (from != null && from.isNotEmpty) {
      args.add(from);
    }

    final result = await runGit(workingDir, args);

    if (result.exitCode != 0) {
      return textResult('Error creating branch: ${result.stderr}');
    }

    return textResult('Created branch: $branch');
  }

  /// List all branches.
  Future<CallToolResult> branchList() async {
    final result = await runGit(workingDir, ['branch', '-a', '-v']);

    if (result.exitCode != 0) {
      return textResult('Error: ${result.stderr}');
    }

    return textResult(result.stdout as String);
  }

  /// Switch to a branch.
  Future<CallToolResult> branchSwitch(String? branch) async {
    if (requireString(branch, 'branch') case final error?) {
      return error;
    }

    final result = await runGit(workingDir, ['checkout', branch!]);

    if (result.exitCode != 0) {
      return textResult('Error switching branch: ${result.stderr}');
    }

    return textResult('Switched to branch: $branch');
  }

  /// Merge a branch (always creates a merge commit, never fast-forward or rebase).
  ///
  /// This ensures proper merge history is maintained. If the current branch has
  /// no commits yet, an empty initial commit is created first to enable a proper merge.
  Future<CallToolResult> merge(String? branch) async {
    if (requireString(branch, 'branch') case final error?) {
      return error;
    }

    // Check if current branch has any commits
    final hasCommits = await _branchHasCommits();

    if (!hasCommits) {
      // Create an empty initial commit to enable proper merge
      final initResult = await runGit(workingDir,
          ['commit', '--allow-empty', '-m', 'Initial commit (created for merge)']);

      if (initResult.exitCode != 0) {
        return textResult(
            'Error: Current branch has no commits and failed to create initial commit.\n'
            'Error: ${initResult.stderr}');
      }
    }

    // Always use --no-ff to ensure a merge commit is created
    final args = ['merge', '--no-ff', branch!];

    final result = await runGit(workingDir, args);

    if (result.exitCode != 0) {
      final stderr = result.stderr as String;
      final stdout = result.stdout as String;

      if (stderr.contains('CONFLICT') || stdout.contains('CONFLICT')) {
        return textResult(
            'Merge conflict detected. Resolve conflicts and commit.\n\n$stdout\n$stderr');
      }

      // Handle case where branches have unrelated histories
      if (stderr.contains('refusing to merge unrelated histories')) {
        final retryArgs = ['merge', '--no-ff', '--allow-unrelated-histories', branch];
        final retryResult = await runGit(workingDir, retryArgs);

        if (retryResult.exitCode != 0) {
          final retryStderr = retryResult.stderr as String;
          final retryStdout = retryResult.stdout as String;
          if (retryStderr.contains('CONFLICT') ||
              retryStdout.contains('CONFLICT')) {
            return textResult(
                'Merge conflict detected. Resolve conflicts and commit.\n\n$retryStdout\n$retryStderr');
          }
          return textResult('Error merging: $retryStderr');
        }

        return textResult(
            'Merged $branch into current branch (with unrelated histories)\n\n${retryResult.stdout}');
      }

      return textResult('Error merging: $stderr');
    }

    return textResult('Merged $branch into current branch\n\n${result.stdout}');
  }

  /// Check if the current branch has any commits.
  Future<bool> _branchHasCommits() async {
    final result = await runGit(workingDir, ['rev-parse', 'HEAD']);
    return result.exitCode == 0;
  }

  /// Stage files.
  Future<CallToolResult> add(List<String>? files, {bool all = false}) async {
    if (all) {
      final statusResult = await runGit(workingDir, ['status', '--porcelain']);
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

        if (isAllowedPath(allowedPaths, absPath)) {
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

      final result = await runGit(workingDir, ['add', '--verbose', ...filesToAdd]);

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
      return validationError(
        'files',
        'files is required. Use ["."] to stage all allowed files, or set all=true.',
      );
    }

    final filesToAdd = <String>[];
    final deniedFiles = <String>[];

    for (final file in files) {
      if (file == '.') {
        return add(null, all: true);
      }

      final absPath = p.isAbsolute(file)
          ? p.normalize(file)
          : p.normalize(p.join(workingDir.path, file));

      if (isAllowedPath(allowedPaths, absPath)) {
        filesToAdd.add(file);
      } else {
        deniedFiles.add(file);
      }
    }

    if (filesToAdd.isEmpty) {
      return validationError(
        'files',
        'None of the specified files are within allowed paths.\n'
        'Denied: ${deniedFiles.join(", ")}\n\n'
        'Allowed paths:\n  ${allowedPaths.join('\n  ')}',
      );
    }

    final result = await runGit(workingDir, ['add', '--verbose', ...filesToAdd]);

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

  /// Commit changes with optional signing.
  ///
  /// Sign parameter:
  /// - 'auto': Use SSH if available, else GPG if available, else no signing
  /// - 'ssh': Force SSH signing (requires SSH key)
  /// - 'gpg': Force GPG signing (requires GPG key and agent)
  /// - 'none': No signing
  Future<CallToolResult> commit(String? message, {required String sign}) async {
    if (requireString(message, 'message') case final error?) {
      return error;
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
        return validationError(
          'sign',
          'SSH signing requested but no SSH key found.\n'
          'Expected key at: ~/.ssh/id_ed25519.pub, ~/.ssh/id_ecdsa.pub, or ~/.ssh/id_rsa.pub\n\n'
          'Use sign="none" to commit without signing, or sign="gpg" for GPG signing.',
        );
      }
      if (!signingInfo.sshAgentHasKey) {
        return validationError(
          'sign',
          'SSH signing requires your key to be loaded in ssh-agent.\n\n'
          'Your key appears to be passphrase-protected. Before launching Claude, run:\n'
          '  ssh-add ~/.ssh/id_rsa\n\n'
          'Or use sign="none" to commit without signing.\n\n'
          'SSH Agent Socket: ${signingInfo.sshAgentSocket ?? "not found"}\n'
          'Keys in agent: ${signingInfo.sshAgentHasKey ? "yes" : "no"}',
        );
      }
    }
    if (actualMethod == 'gpg' && !signingInfo.gpgAvailable) {
      return validationError(
        'sign',
        'GPG signing requested but no GPG key found.\n'
        'Run "gpg --list-secret-keys" to check your keys.\n\n'
        'Use sign="none" to commit without signing, or sign="ssh" for SSH signing.',
      );
    }

    final args = <String>['commit'];
    bool forGpgSign = false;
    bool forSshSign = false;

    switch (actualMethod) {
      case 'ssh':
        final sshKeyPath = signingInfo.sshKeyPath ?? await getSSHKeyPath();
        if (sshKeyPath == null) {
          return validationError('sign', 'Could not find SSH key for signing');
        }

        args.insertAll(0, [
          '-c',
          'gpg.format=ssh',
          '-c',
          'user.signingkey=$sshKeyPath',
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

    args.addAll(['-m', message!]);

    final result = await runGit(
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
              'Original error: ${result.stderr}');
        }
        if (stderr.contains('error: Load key') ||
            stderr.contains('invalid format')) {
          return textResult('Error: SSH signing failed - could not load key.\n'
              'Make sure your SSH key exists and is valid.\n\n'
              'Original error: ${result.stderr}');
        }
      }

      if (actualMethod == 'gpg') {
        if (stderr.contains('secret key not available') ||
            stderr.contains('No secret key')) {
          return textResult(
              'Error: GPG signing failed - no secret key available.\n'
              'Make sure you have configured git with a valid signing key:\n'
              '  git config user.signingkey <KEY_ID>\n\n'
              'Original error: ${result.stderr}');
        }
        if (stderr.contains('agent') || stderr.contains('socket')) {
          return textResult(
              'Error: GPG signing failed - cannot connect to gpg-agent.\n'
              'Make sure gpg-agent is running:\n'
              '  gpgconf --launch gpg-agent\n\n'
              'Or commit with sign="none" or sign="ssh".\n\n'
              'Original error: ${result.stderr}');
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

  /// Stash changes.
  Future<CallToolResult> stash(String? message, {bool includeUntracked = false}) async {
    final args = ['stash', 'push'];

    if (includeUntracked) {
      args.add('--include-untracked');
    }

    if (message != null && message.isNotEmpty) {
      args.addAll(['-m', message]);
    }

    final result = await runGit(workingDir, args);

    if (result.exitCode != 0) {
      return textResult('Error stashing: ${result.stderr}');
    }

    final output = result.stdout as String;
    if (output.contains('No local changes to save')) {
      return textResult('No changes to stash');
    }

    final untrackedNote = includeUntracked ? ' (including untracked files)' : '';
    return textResult(
        'Stashed changes$untrackedNote${message != null ? ": $message" : ""}\n\n$output');
  }

  /// List stashes.
  Future<CallToolResult> stashList() async {
    final result = await runGit(workingDir, ['stash', 'list']);

    if (result.exitCode != 0) {
      return textResult('Error: ${result.stderr}');
    }

    final output = result.stdout as String;
    if (output.trim().isEmpty) {
      return textResult('No stashes');
    }

    return textResult(output);
  }

  /// Apply or pop a stash.
  Future<CallToolResult> stashApply(int index, {required bool pop}) async {
    final command = pop ? 'pop' : 'apply';
    final result = await runGit(workingDir, ['stash', command, 'stash@{$index}']);

    if (result.exitCode != 0) {
      return textResult('Error applying stash: ${result.stderr}');
    }

    final action = pop ? 'Popped' : 'Applied';
    return textResult('$action stash@{$index}\n\n${result.stdout}');
  }

  /// Create a tag.
  Future<CallToolResult> tagCreate(String? tag, String? message, bool annotated) async {
    if (requireString(tag, 'tag') case final error?) {
      return error;
    }

    final args = ['tag'];

    if (annotated || (message != null && message.isNotEmpty)) {
      args.add('-a');
      args.add(tag!);
      args.addAll(['-m', message ?? tag]);
    } else {
      args.add(tag!);
    }

    final result = await runGit(workingDir, args);

    if (result.exitCode != 0) {
      return textResult('Error creating tag: ${result.stderr}');
    }

    final tagType = annotated ? 'annotated tag' : 'tag';
    return textResult('Created $tagType: $tag');
  }

  /// List tags.
  Future<CallToolResult> tagList() async {
    final result = await runGit(workingDir, ['tag', '-l', '-n1']);

    if (result.exitCode != 0) {
      return textResult('Error: ${result.stderr}');
    }

    final output = result.stdout as String;
    if (output.trim().isEmpty) {
      return textResult('No tags');
    }

    return textResult(output);
  }

  /// Show commit log.
  Future<CallToolResult> log(int maxCount) async {
    final result = await runGit(workingDir, [
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

  /// Show diff.
  Future<CallToolResult> diff() async {
    final stagedResult = await runGit(workingDir, ['diff', '--cached']);
    final unstagedResult = await runGit(workingDir, ['diff']);

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
}

/// Extract files argument from args map.
List<String>? getFilesArg(Map<String, dynamic>? args) {
  final files = args?['files'];
  if (files is List) {
    return files.cast<String>();
  }
  return null;
}
