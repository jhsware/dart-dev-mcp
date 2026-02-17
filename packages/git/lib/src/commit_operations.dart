import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'package:jhsware_code_shared_libs/shared_libs.dart';

import 'git_runner.dart';
import 'signing.dart';

/// Git commit and stash operations handler.
///
/// Provides commit (with optional SSH/GPG signing) and stash operations
/// as methods returning [CallToolResult].
class CommitOperations {
  final Directory workingDir;
  final SigningInfo signingInfo;

  CommitOperations({
    required this.workingDir,
    required this.signingInfo,
  });

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
}
