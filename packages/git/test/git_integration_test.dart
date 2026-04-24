import 'dart:io';

import 'package:git_mcp/git_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Integration tests for git operations including SSH and GPG signing
/// 
/// These tests create real temporary git repositories and test operations.
/// All SSH keys are generated in temporary directories - never in $HOME/.ssh
void main() {
  group('Git Integration Tests', () {
    late Directory tempDir;
    late Directory repoDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('git_mcp_test_');
      repoDir = Directory(p.join(tempDir.path, 'test_repo'));
      await repoDir.create();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('can init, add, and commit without signing', () async {
      var result = await Process.run(
        'git', ['init'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0, reason: 'git init failed: ${result.stderr}');

      result = await Process.run(
        'git', ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0);

      result = await Process.run(
        'git', ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0);

      final testFile = File(p.join(repoDir.path, 'test.txt'));
      await testFile.writeAsString('Hello, World!\n');

      result = await Process.run(
        'git', ['add', 'test.txt'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0);

      result = await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'Initial commit'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0, reason: 'git commit failed: ${result.stderr}');

      result = await Process.run(
        'git', ['log', '--oneline'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Initial commit'));
    });

    test('commit works in restricted environment', () async {
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git', ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
      );

      final testFile = File(p.join(repoDir.path, 'src', 'main.dart'));
      await testFile.parent.create(recursive: true);
      await testFile.writeAsString('void main() => print("Hello");\n');

      final restrictedEnv = <String, String>{
        'HOME': Platform.environment['HOME'] ?? '/tmp',
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'USER': Platform.environment['USER'] ?? 'test',
      };

      var result = await Process.run(
        'git', ['add', 'src/main.dart'],
        workingDirectory: repoDir.path,
        environment: restrictedEnv,
      );
      expect(result.exitCode, 0);

      result = await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'Add main.dart'],
        workingDirectory: repoDir.path,
        environment: restrictedEnv,
      );
      expect(result.exitCode, 0, reason: 'Commit failed: ${result.stderr}');

      result = await Process.run(
        'git', ['log', '--oneline'],
        workingDirectory: repoDir.path,
      );
      expect(result.stdout, contains('Add main.dart'));
    });

    test('branch-create auto-switches to the new branch', () async {
      // Init repo and create initial commit
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git', ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
      );

      final testFile = File(p.join(repoDir.path, 'init.txt'));
      await testFile.writeAsString('initial\n');

      await Process.run(
        'git', ['add', 'init.txt'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'Initial commit'],
        workingDirectory: repoDir.path,
      );

      // Verify we start on master/main
      var result = await Process.run(
        'git', ['rev-parse', '--abbrev-ref', 'HEAD'],
        workingDirectory: repoDir.path,
      );
      final defaultBranch = (result.stdout as String).trim();
      expect(defaultBranch, anyOf('master', 'main'));

      // Simulate branchCreate: use checkout -b (the new behavior)
      result = await Process.run(
        'git', ['checkout', '-b', 'feature-test'],
        workingDirectory: repoDir.path,
      );
      expect(result.exitCode, 0, reason: 'checkout -b failed: ${result.stderr}');

      // Verify we are now on the new branch
      result = await Process.run(
        'git', ['rev-parse', '--abbrev-ref', 'HEAD'],
        workingDirectory: repoDir.path,
      );
      expect((result.stdout as String).trim(), 'feature-test');

      // Also test with 'from' parameter (checkout -b <name> <from>)
      result = await Process.run(
        'git', ['checkout', defaultBranch],
        workingDirectory: repoDir.path,
      );
      expect(result.exitCode, 0);

      result = await Process.run(
        'git', ['checkout', '-b', 'feature-from-test', defaultBranch],
        workingDirectory: repoDir.path,
      );
      expect(result.exitCode, 0, reason: 'checkout -b with from failed: ${result.stderr}');

      result = await Process.run(
        'git', ['rev-parse', '--abbrev-ref', 'HEAD'],
        workingDirectory: repoDir.path,
      );
      expect((result.stdout as String).trim(), 'feature-from-test');
    });

  });

  group('Diff Operation Tests', () {
    late Directory tempDir;
    late Directory repoDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('git_diff_test_');
      repoDir = Directory(p.join(tempDir.path, 'test_repo'));
      await repoDir.create();

      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git', ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('default diff shows staged and unstaged changes', () async {
      // Create initial commit
      final testFile = File(p.join(repoDir.path, 'file.txt'));
      await testFile.writeAsString('original content\n');
      await Process.run('git', ['add', 'file.txt'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'Initial commit'],
        workingDirectory: repoDir.path,
      );

      // Make an unstaged change
      await testFile.writeAsString('modified content\n');

      // Default diff (no target) should show unstaged changes
      var result = await Process.run(
        'git', ['diff'],
        workingDirectory: repoDir.path,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('modified content'));
      expect(result.stdout, contains('original content'));

      // Stage the change and check staged diff
      await Process.run('git', ['add', 'file.txt'], workingDirectory: repoDir.path);
      result = await Process.run(
        'git', ['diff', '--cached'],
        workingDirectory: repoDir.path,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('modified content'));
    });

    test('diff with branch target compares working tree to branch', () async {
      // Create initial commit on default branch
      final testFile = File(p.join(repoDir.path, 'file.txt'));
      await testFile.writeAsString('main content\n');
      await Process.run('git', ['add', 'file.txt'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'Initial commit'],
        workingDirectory: repoDir.path,
      );

      // Get default branch name
      var result = await Process.run(
        'git', ['rev-parse', '--abbrev-ref', 'HEAD'],
        workingDirectory: repoDir.path,
      );
      final defaultBranch = (result.stdout as String).trim();

      // Create feature branch with different content
      await Process.run(
        'git', ['checkout', '-b', 'feature-branch'],
        workingDirectory: repoDir.path,
      );
      await testFile.writeAsString('feature content\n');
      await Process.run('git', ['add', 'file.txt'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'Feature commit'],
        workingDirectory: repoDir.path,
      );

      // Diff against default branch: git diff <default-branch>
      result = await Process.run(
        'git', ['diff', defaultBranch],
        workingDirectory: repoDir.path,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('main content'));
      expect(result.stdout, contains('feature content'));
    });

    test('diff with commit range compares two refs', () async {
      // Create initial commit
      final testFile = File(p.join(repoDir.path, 'file.txt'));
      await testFile.writeAsString('version 1\n');
      await Process.run('git', ['add', 'file.txt'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'First commit'],
        workingDirectory: repoDir.path,
      );

      // Get first commit hash
      var result = await Process.run(
        'git', ['rev-parse', 'HEAD'],
        workingDirectory: repoDir.path,
      );
      final firstCommit = (result.stdout as String).trim();

      // Create second commit
      await testFile.writeAsString('version 2\n');
      await Process.run('git', ['add', 'file.txt'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'Second commit'],
        workingDirectory: repoDir.path,
      );

      // Get second commit hash
      result = await Process.run(
        'git', ['rev-parse', 'HEAD'],
        workingDirectory: repoDir.path,
      );
      final secondCommit = (result.stdout as String).trim();

      // Diff with commit range
      result = await Process.run(
        'git', ['diff', '$firstCommit..$secondCommit'],
        workingDirectory: repoDir.path,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('version 1'));
      expect(result.stdout, contains('version 2'));
    });

    test('diff with branch range using double-dot notation', () async {
      // Create initial commit on default branch
      final testFile = File(p.join(repoDir.path, 'file.txt'));
      await testFile.writeAsString('base content\n');
      await Process.run('git', ['add', 'file.txt'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'Base commit'],
        workingDirectory: repoDir.path,
      );

      // Get default branch name
      var result = await Process.run(
        'git', ['rev-parse', '--abbrev-ref', 'HEAD'],
        workingDirectory: repoDir.path,
      );
      final defaultBranch = (result.stdout as String).trim();

      // Create feature branch with different content
      await Process.run(
        'git', ['checkout', '-b', 'feature-diff'],
        workingDirectory: repoDir.path,
      );
      await testFile.writeAsString('feature diff content\n');
      await Process.run('git', ['add', 'file.txt'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'Feature diff commit'],
        workingDirectory: repoDir.path,
      );

      // Diff using branch range notation: main..feature-diff
      result = await Process.run(
        'git', ['diff', '$defaultBranch..feature-diff'],
        workingDirectory: repoDir.path,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('base content'));
      expect(result.stdout, contains('feature diff content'));

      // No changes when comparing same ref
      result = await Process.run(
        'git', ['diff', 'feature-diff..feature-diff'],
        workingDirectory: repoDir.path,
      );
      expect(result.exitCode, 0);
      expect((result.stdout as String).trim(), isEmpty);
    });
  });


  group('SSH Signing Tests', () {
    late Directory tempDir;
    late Directory repoDir;
    late Directory sshDir;
    late String sshKeyPath;
    late bool gitSupportsSSH;

    setUpAll(() async {
      // Check git version for SSH signing support (requires 2.34+)
      final gitVersion = await Process.run('git', ['--version']);
      if (gitVersion.exitCode == 0) {
        final versionStr = (gitVersion.stdout as String).trim();
        final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(versionStr);
        if (match != null) {
          final major = int.parse(match.group(1)!);
          final minor = int.parse(match.group(2)!);
          gitSupportsSSH = major > 2 || (major == 2 && minor >= 34);
        } else {
          gitSupportsSSH = false;
        }
        print('Git version: $versionStr (SSH signing: ${gitSupportsSSH ? "supported" : "not supported"})');
      } else {
        gitSupportsSSH = false;
      }
    });

    setUp(() async {
      if (!gitSupportsSSH) return;
      
      tempDir = await Directory.systemTemp.createTemp('git_ssh_test_');
      repoDir = Directory(p.join(tempDir.path, 'test_repo'));
      sshDir = Directory(p.join(tempDir.path, 'ssh'));
      await repoDir.create();
      await sshDir.create();
      
      // Generate a test SSH key (no passphrase) in TEMP directory, not $HOME/.ssh
      sshKeyPath = p.join(sshDir.path, 'id_ed25519');
      final keygenResult = await Process.run(
        'ssh-keygen',
        ['-t', 'ed25519', '-f', sshKeyPath, '-N', '', '-C', 'test@example.com'],
      );
      
      if (keygenResult.exitCode != 0) {
        print('Failed to generate SSH key: ${keygenResult.stderr}');
        return;
      }
      
      print('Generated test SSH key: $sshKeyPath');
      
      // Initialize git repo
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git', ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
      );
    });

    tearDown(() async {
      if (!gitSupportsSSH) return;
      
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('SSH key can be generated for testing', () async {
      if (!gitSupportsSSH) {
        markTestSkipped('Git does not support SSH signing (requires 2.34+)');
        return;
      }
      
      expect(await File(sshKeyPath).exists(), isTrue);
      expect(await File('$sshKeyPath.pub').exists(), isTrue);
      
      // Verify key format
      final pubKey = await File('$sshKeyPath.pub').readAsString();
      expect(pubKey, contains('ssh-ed25519'));
    });

    test('can commit with SSH signing using -c config options', () async {
      if (!gitSupportsSSH) {
        markTestSkipped('Git does not support SSH signing (requires 2.34+)');
        return;
      }
      
      // Create a file
      final testFile = File(p.join(repoDir.path, 'signed_file.txt'));
      await testFile.writeAsString('This commit will be SSH signed\n');
      
      // Stage the file
      var result = await Process.run(
        'git', ['add', 'signed_file.txt'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0);
      
      // Commit with SSH signing using -c options (same approach as git_mcp.dart)
      result = await Process.run(
        'git',
        [
          '-c', 'gpg.format=ssh',
          '-c', 'user.signingkey=$sshKeyPath.pub',
          'commit', '-S', '-m', 'SSH signed commit'
        ],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      
      print('SSH commit stdout: ${result.stdout}');
      print('SSH commit stderr: ${result.stderr}');
      
      expect(result.exitCode, 0, reason: 'SSH-signed commit failed: ${result.stderr}');
      
      // Verify the commit exists
      result = await Process.run(
        'git', ['log', '--oneline'],
        workingDirectory: repoDir.path,
      );
      expect(result.stdout, contains('SSH signed commit'));
      
      // Show signature (won't validate without allowed_signers, but shows it was signed)
      result = await Process.run(
        'git', ['log', '--show-signature', '-1'],
        workingDirectory: repoDir.path,
      );
      print('Commit with signature info:\n${result.stdout}${result.stderr}');
    });

    test('can configure allowed_signers for SSH signature verification', () async {
      if (!gitSupportsSSH) {
        markTestSkipped('Git does not support SSH signing (requires 2.34+)');
        return;
      }
      
      // Create allowed_signers file
      final pubKey = await File('$sshKeyPath.pub').readAsString();
      final allowedSignersPath = p.join(tempDir.path, 'allowed_signers');
      await File(allowedSignersPath).writeAsString('test@example.com $pubKey');
      
      // Configure git to use allowed_signers
      await Process.run(
        'git', ['config', 'gpg.ssh.allowedSignersFile', allowedSignersPath],
        workingDirectory: repoDir.path,
      );
      
      // Create and commit a file with SSH signing
      final testFile = File(p.join(repoDir.path, 'verified_file.txt'));
      await testFile.writeAsString('This commit will be verified\n');
      
      await Process.run(
        'git', ['add', 'verified_file.txt'],
        workingDirectory: repoDir.path,
      );
      
      var result = await Process.run(
        'git',
        [
          '-c', 'gpg.format=ssh',
          '-c', 'user.signingkey=$sshKeyPath.pub',
          'commit', '-S', '-m', 'Verified SSH commit'
        ],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0);
      
      // Verify signature
      result = await Process.run(
        'git', ['log', '--show-signature', '-1'],
        workingDirectory: repoDir.path,
      );
      
      print('Signature verification:\n${result.stdout}${result.stderr}');
      
      // Should show "Good signature" when allowed_signers is configured
      // Note: git shows 'Good "git" signature' for SSH signatures
      expect(
        '${result.stdout}${result.stderr}',
        anyOf(
          contains('Good'),
          contains('good'),
          contains('Signature made'), // Some git versions show this
        ),
      );
    });

    test('SSH signing fails gracefully without valid key', () async {
      if (!gitSupportsSSH) {
        markTestSkipped('Git does not support SSH signing (requires 2.34+)');
        return;
      }
      
      // Create a file
      final testFile = File(p.join(repoDir.path, 'test.txt'));
      await testFile.writeAsString('Test\n');
      
      await Process.run(
        'git', ['add', 'test.txt'],
        workingDirectory: repoDir.path,
      );
      
      // Try to sign with non-existent key
      final result = await Process.run(
        'git',
        [
          '-c', 'gpg.format=ssh',
          '-c', 'user.signingkey=/nonexistent/key.pub',
          'commit', '-S', '-m', 'This should fail'
        ],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      
      print('Expected failure stderr: ${result.stderr}');
      
      expect(result.exitCode, isNot(0), reason: 'Commit should fail with invalid key');
    });
  });

  group('SSH Agent Signing Tests', () {
    late Directory tempDir;
    late Directory repoDir;
    late Directory sshDir;
    late String sshKeyPath;
    late String sshAgentSocket;
    late int sshAgentPid;
    late bool gitSupportsSSH;
    late bool sshAgentStarted;
    
    const testPassphrase = 'test-passphrase-123';

    setUpAll(() async {
      // Check git version for SSH signing support (requires 2.34+)
      final gitVersion = await Process.run('git', ['--version']);
      if (gitVersion.exitCode == 0) {
        final versionStr = (gitVersion.stdout as String).trim();
        final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(versionStr);
        if (match != null) {
          final major = int.parse(match.group(1)!);
          final minor = int.parse(match.group(2)!);
          gitSupportsSSH = major > 2 || (major == 2 && minor >= 34);
        } else {
          gitSupportsSSH = false;
        }
        print('Git version: $versionStr (SSH signing: ${gitSupportsSSH ? "supported" : "not supported"})');
      } else {
        gitSupportsSSH = false;
      }
    });

    setUp(() async {
      sshAgentStarted = false;
      
      if (!gitSupportsSSH) return;
      
      tempDir = await Directory.systemTemp.createTemp('git_ssh_agent_test_');
      repoDir = Directory(p.join(tempDir.path, 'test_repo'));
      sshDir = Directory(p.join(tempDir.path, 'ssh'));
      await repoDir.create();
      await sshDir.create();
      
      // Generate a test SSH key WITH passphrase in TEMP directory, not $HOME/.ssh
      sshKeyPath = p.join(sshDir.path, 'id_ed25519');
      var keygenResult = await Process.run(
        'ssh-keygen',
        ['-t', 'ed25519', '-f', sshKeyPath, '-N', testPassphrase, '-C', 'test@example.com'],
      );
      
      if (keygenResult.exitCode != 0) {
        print('Failed to generate SSH key with passphrase: ${keygenResult.stderr}');
        return;
      }
      
      print('Generated passphrase-protected SSH key: $sshKeyPath');
      
      // Start a temporary ssh-agent
      final agentResult = await Process.run('ssh-agent', ['-s']);
      if (agentResult.exitCode != 0) {
        print('Failed to start ssh-agent: ${agentResult.stderr}');
        return;
      }
      
      // Parse ssh-agent output to get SSH_AUTH_SOCK and SSH_AGENT_PID
      // Output format: SSH_AUTH_SOCK=/tmp/ssh-xxx/agent.xxx; export SSH_AUTH_SOCK;
      //                SSH_AGENT_PID=12345; export SSH_AGENT_PID;
      final agentOutput = agentResult.stdout as String;
      final sockMatch = RegExp(r'SSH_AUTH_SOCK=([^;]+)').firstMatch(agentOutput);
      final pidMatch = RegExp(r'SSH_AGENT_PID=(\d+)').firstMatch(agentOutput);
      
      if (sockMatch == null || pidMatch == null) {
        print('Failed to parse ssh-agent output: $agentOutput');
        return;
      }
      
      sshAgentSocket = sockMatch.group(1)!;
      sshAgentPid = int.parse(pidMatch.group(1)!);
      sshAgentStarted = true;
      
      print('Started ssh-agent (PID: $sshAgentPid, socket: $sshAgentSocket)');
      
      // Add the key to the agent using SSH_ASKPASS
      // Create a temporary script that echoes the passphrase
      final askpassScript = File(p.join(tempDir.path, 'askpass.sh'));
      await askpassScript.writeAsString('#!/bin/sh\necho "$testPassphrase"');
      await Process.run('chmod', ['+x', askpassScript.path]);
      
      // Add key to agent
      final addResult = await Process.run(
        'ssh-add',
        [sshKeyPath],
        environment: {
          ...Platform.environment,
          'SSH_AUTH_SOCK': sshAgentSocket,
          'SSH_ASKPASS': askpassScript.path,
          'SSH_ASKPASS_REQUIRE': 'force',
          'DISPLAY': ':0', // Required for SSH_ASKPASS to work
        },
      );
      
      if (addResult.exitCode != 0) {
        print('Failed to add key to agent: ${addResult.stderr}');
        // Try alternative method using expect-like approach
        print('Trying alternative method...');
      } else {
        print('Added key to ssh-agent');
      }
      
      // Verify key was added
      final listResult = await Process.run(
        'ssh-add',
        ['-l'],
        environment: {
          'SSH_AUTH_SOCK': sshAgentSocket,
        },
      );
      print('Keys in agent: ${listResult.stdout}');
      
      // Initialize git repo
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git', ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
      );
    });

    tearDown(() async {
      // Kill the ssh-agent
      if (sshAgentStarted) {
        try {
          await Process.run('kill', [sshAgentPid.toString()]);
          print('Killed ssh-agent (PID: $sshAgentPid)');
        } catch (e) {
          print('Failed to kill ssh-agent: $e');
        }
      }
      
      if (!gitSupportsSSH) return;
      
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('can start ssh-agent and add passphrase-protected key', () async {
      if (!gitSupportsSSH) {
        markTestSkipped('Git does not support SSH signing (requires 2.34+)');
        return;
      }
      
      if (!sshAgentStarted) {
        markTestSkipped('ssh-agent could not be started');
        return;
      }
      
      // Verify agent is running and has our key
      final listResult = await Process.run(
        'ssh-add',
        ['-l'],
        environment: {
          'SSH_AUTH_SOCK': sshAgentSocket,
        },
      );
      
      print('ssh-add -l exit code: ${listResult.exitCode}');
      print('ssh-add -l stdout: ${listResult.stdout}');
      print('ssh-add -l stderr: ${listResult.stderr}');
      
      expect(listResult.exitCode, 0, reason: 'ssh-agent should have keys loaded');
      expect(listResult.stdout, contains('ED25519'), reason: 'Our test key should be in agent');
    });

    test('can sign commits using ssh-agent with passphrase-protected key', () async {
      if (!gitSupportsSSH) {
        markTestSkipped('Git does not support SSH signing (requires 2.34+)');
        return;
      }
      
      if (!sshAgentStarted) {
        markTestSkipped('ssh-agent could not be started');
        return;
      }
      
      // Check if key is in agent
      final listResult = await Process.run(
        'ssh-add',
        ['-l'],
        environment: {
          'SSH_AUTH_SOCK': sshAgentSocket,
        },
      );
      
      if (listResult.exitCode != 0) {
        // Key not in agent - try to add it using expect
        print('Key not in agent, trying to add via expect...');
        
        // Check if expect is available
        final expectCheck = await Process.run('which', ['expect']);
        if (expectCheck.exitCode != 0) {
          markTestSkipped('expect not available and key not in agent');
          return;
        }
        
        // Create expect script to add key
        final expectScript = '''
#!/usr/bin/expect -f
spawn ssh-add $sshKeyPath
expect "Enter passphrase"
send "$testPassphrase\\r"
expect eof
''';
        final expectFile = File(p.join(tempDir.path, 'add_key.exp'));
        await expectFile.writeAsString(expectScript);
        await Process.run('chmod', ['+x', expectFile.path]);
        
        final addResult = await Process.run(
          expectFile.path,
          [],
          environment: {
            ...Platform.environment,
            'SSH_AUTH_SOCK': sshAgentSocket,
          },
        );
        
        print('expect script result: ${addResult.exitCode}');
        print('expect stdout: ${addResult.stdout}');
        print('expect stderr: ${addResult.stderr}');
        
        // Verify key was added
        final verifyResult = await Process.run(
          'ssh-add',
          ['-l'],
          environment: {
            'SSH_AUTH_SOCK': sshAgentSocket,
          },
        );
        
        if (verifyResult.exitCode != 0) {
          markTestSkipped('Could not add passphrase-protected key to agent');
          return;
        }
      }
      
      // Create a file
      final testFile = File(p.join(repoDir.path, 'agent_signed.txt'));
      await testFile.writeAsString('This commit uses ssh-agent for signing\n');
      
      // Stage the file
      var result = await Process.run(
        'git', ['add', 'agent_signed.txt'],
        workingDirectory: repoDir.path,
      );
      expect(result.exitCode, 0);
      
      // Commit with SSH signing via agent
      // The key point: we pass SSH_AUTH_SOCK to git, and it uses the agent
      // No passphrase prompt is needed because ssh-agent has it cached!
      result = await Process.run(
        'git',
        [
          '-c', 'gpg.format=ssh',
          '-c', 'user.signingkey=$sshKeyPath.pub',
          'commit', '-S', '-m', 'Commit signed via ssh-agent'
        ],
        workingDirectory: repoDir.path,
        environment: {
          ...Platform.environment,
          'SSH_AUTH_SOCK': sshAgentSocket,
        },
      );
      
      print('SSH agent commit stdout: ${result.stdout}');
      print('SSH agent commit stderr: ${result.stderr}');
      
      expect(result.exitCode, 0, reason: 'SSH-signed commit via agent failed: ${result.stderr}');
      
      // Verify the commit exists
      result = await Process.run(
        'git', ['log', '--oneline'],
        workingDirectory: repoDir.path,
      );
      expect(result.stdout, contains('Commit signed via ssh-agent'));
      
      // Show signature
      result = await Process.run(
        'git', ['log', '--show-signature', '-1'],
        workingDirectory: repoDir.path,
        environment: {
          'SSH_AUTH_SOCK': sshAgentSocket,
        },
      );
      print('Commit signature info:\n${result.stdout}${result.stderr}');
    });

    test('SSH signing fails without agent for passphrase-protected key', () async {
      if (!gitSupportsSSH) {
        markTestSkipped('Git does not support SSH signing (requires 2.34+)');
        return;
      }
      
      if (!sshAgentStarted) {
        markTestSkipped('ssh-agent could not be started');
        return;
      }
      
      // Create a file
      final testFile = File(p.join(repoDir.path, 'test_no_agent.txt'));
      await testFile.writeAsString('Test without agent\n');
      
      await Process.run(
        'git', ['add', 'test_no_agent.txt'],
        workingDirectory: repoDir.path,
      );
      
      // Try to sign WITHOUT passing SSH_AUTH_SOCK
      // This should fail because the key has a passphrase
      final result = await Process.run(
        'git',
        [
          '-c', 'gpg.format=ssh',
          '-c', 'user.signingkey=$sshKeyPath.pub',
          'commit', '-S', '-m', 'This should fail without agent'
        ],
        includeParentEnvironment: false,
        workingDirectory: repoDir.path,
        environment: {
          'HOME': Platform.environment['HOME'] ?? '/tmp',
          'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
          'USER': Platform.environment['USER'] ?? 'test',
          'SSH_ASKPASS': '/bin/false',  // Use false to immediately fail password prompts
          'SSH_ASKPASS_REQUIRE': 'force',  // Force SSH to prompt for passphrase using SSH_ASKPASS
          // No SSH_AUTH_SOCK!
        },
      );
      
      print('Expected failure (no agent) stderr: ${result.stderr}');
      
      // Should fail because key requires passphrase but no agent
      expect(result.exitCode, isNot(0), 
          reason: 'Commit should fail without SSH_AUTH_SOCK for passphrase-protected key');
      expect(result.stderr, contains('passphrase'),
          reason: 'Error should mention passphrase');
    });

    test('verifies SSH_AUTH_SOCK environment passing', () async {
      if (!gitSupportsSSH) {
        markTestSkipped('Git does not support SSH signing (requires 2.34+)');
        return;
      }
      
      if (!sshAgentStarted) {
        markTestSkipped('ssh-agent could not be started');
        return;
      }
      
      // This test verifies that passing SSH_AUTH_SOCK works correctly
      // It simulates what claude.sh does when passing env to the MCP server
      
      final envWithAgent = {
        ...Platform.environment,
        'SSH_AUTH_SOCK': sshAgentSocket,
      };
      
      final envWithoutAgent = {
        'HOME': Platform.environment['HOME'] ?? '/tmp',
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'USER': Platform.environment['USER'] ?? 'test',
        // No SSH_AUTH_SOCK
      };
      
      // With agent socket - should list keys
      var result = await Process.run(
        'ssh-add', ['-l'],
        environment: envWithAgent,
      );
      print('With SSH_AUTH_SOCK: exit=${result.exitCode}, keys=${result.stdout}');
      expect(result.exitCode, anyOf(0, 1)); // 0 = keys, 1 = no keys, both OK
      
      // Without agent socket - should fail to connect
      result = await Process.run(
        'ssh-add', ['-l'],
        includeParentEnvironment: false,
        environment: envWithoutAgent,
      );
      print('Without SSH_AUTH_SOCK: exit=${result.exitCode}, stderr=${result.stderr}');
      expect(result.exitCode, 2, reason: 'Should fail to connect without SSH_AUTH_SOCK');
    });
  });

  group('GPG Signing Tests', () {
    late Directory tempDir;
    late Directory repoDir;
    late Directory gnupgDir;
    late String? testKeyId;
    late bool gpgAvailable;

    setUpAll(() async {
      final gpgCheck = await Process.run('which', ['gpg']);
      gpgAvailable = gpgCheck.exitCode == 0;
      
      if (gpgAvailable) {
        final versionResult = await Process.run('gpg', ['--version']);
        print('GPG version: ${(versionResult.stdout as String).split('\n').first}');
      } else {
        print('GPG not available - GPG signing tests will be skipped');
      }
    });

    setUp(() async {
      if (!gpgAvailable) return;
      
      tempDir = await Directory.systemTemp.createTemp('git_gpg_test_');
      repoDir = Directory(p.join(tempDir.path, 'test_repo'));
      gnupgDir = Directory(p.join(tempDir.path, 'gnupg'));
      await repoDir.create();
      await gnupgDir.create();
      
      await Process.run('chmod', ['700', gnupgDir.path]);
      
      // Create a test GPG key (no passphrase) in TEMP directory, not $HOME/.gnupg
      final keyParams = '''
%echo Generating test key
%no-protection
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: Test User
Name-Email: test@example.com
Expire-Date: 0
%commit
%echo Done
''';

      final paramsFile = File(p.join(tempDir.path, 'key_params'));
      await paramsFile.writeAsString(keyParams);
      
      final genResult = await Process.run(
        'gpg',
        ['--batch', '--gen-key', paramsFile.path],
        environment: {
          ...Platform.environment,
          'GNUPGHOME': gnupgDir.path,
        },
      );
      
      if (genResult.exitCode != 0) {
        print('Failed to generate test GPG key: ${genResult.stderr}');
        testKeyId = null;
        return;
      }
      
      final listResult = await Process.run(
        'gpg',
        ['--list-secret-keys', '--keyid-format', 'LONG'],
        environment: {
          ...Platform.environment,
          'GNUPGHOME': gnupgDir.path,
        },
      );
      
      if (listResult.exitCode == 0) {
        final output = listResult.stdout as String;
        final match = RegExp(r'sec\s+rsa\d+/([A-F0-9]+)').firstMatch(output);
        testKeyId = match?.group(1);
        print('Test GPG key created: $testKeyId');
      }
      
      // Initialize git repo
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git', ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
      );
    });

    tearDown(() async {
      if (!gpgAvailable) return;
      
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('can commit with GPG signing', () async {
      if (!gpgAvailable || testKeyId == null) {
        markTestSkipped('GPG not available or key not created');
        return;
      }
      
      final gpgEnv = {
        ...Platform.environment,
        'GNUPGHOME': gnupgDir.path,
        'GPG_TTY': '/dev/tty',
      };
      
      // Configure git for GPG signing
      await Process.run(
        'git', ['config', 'gpg.format', 'openpgp'],  // Explicitly use GPG, not SSH
        workingDirectory: repoDir.path,
        environment: gpgEnv,
      );
      await Process.run(
        'git', ['config', 'user.signingkey', testKeyId!],
        workingDirectory: repoDir.path,
        environment: gpgEnv,
      );
      
      final gpgPath = (await Process.run('which', ['gpg'])).stdout.toString().trim();
      await Process.run(
        'git', ['config', 'gpg.program', gpgPath],
        workingDirectory: repoDir.path,
        environment: gpgEnv,
      );
      
      final testFile = File(p.join(repoDir.path, 'gpg_signed.txt'));
      await testFile.writeAsString('GPG signed content\n');
      
      var result = await Process.run(
        'git', ['add', 'gpg_signed.txt'],
        workingDirectory: repoDir.path,
        environment: gpgEnv,
      );
      expect(result.exitCode, 0);
      
      result = await Process.run(
        'git', ['commit', '-S', '-m', 'GPG signed commit'],
        workingDirectory: repoDir.path,
        environment: gpgEnv,
      );
      
      print('GPG commit stdout: ${result.stdout}');
      print('GPG commit stderr: ${result.stderr}');
      
      expect(result.exitCode, 0, reason: 'GPG-signed commit failed: ${result.stderr}');
      
      result = await Process.run(
        'git', ['log', '--show-signature', '-1'],
        workingDirectory: repoDir.path,
        environment: gpgEnv,
      );
      
      expect(result.stdout, contains('GPG signed commit'));
    });
  });

  group('Signing Detection', () {
    test('can detect git version for SSH support', () async {
      final gitVersion = await Process.run('git', ['--version']);
      expect(gitVersion.exitCode, 0);
      
      final versionStr = (gitVersion.stdout as String).trim();
      print('Git version string: $versionStr');
      
      final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(versionStr);
      expect(match, isNotNull);
      
      final major = int.parse(match!.group(1)!);
      final minor = int.parse(match.group(2)!);
      final patch = int.parse(match.group(3)!);
      
      print('Parsed version: $major.$minor.$patch');
      
      final supportsSSH = major > 2 || (major == 2 && minor >= 34);
      print('SSH signing supported: $supportsSSH');
    });

    test('can find SSH keys', () async {
      final home = Platform.environment['HOME'];
      expect(home, isNotNull);
      
      final sshKeyPaths = [
        '$home/.ssh/id_ed25519.pub',
        '$home/.ssh/id_ecdsa.pub',
        '$home/.ssh/id_rsa.pub',
      ];
      
      print('Checking for SSH keys:');
      bool foundKey = false;
      for (final path in sshKeyPaths) {
        final exists = await File(path).exists();
        print('  $path: ${exists ? "found" : "not found"}');
        if (exists) foundKey = true;
      }
      
      if (foundKey) {
        print('SSH signing is available');
      } else {
        print('No SSH keys found - SSH signing not available');
      }
    });

    test('can check GPG availability', () async {
      try {
        final gpgCheck = await Process.run('gpg', ['--list-secret-keys', '--keyid-format', 'LONG']);
        if (gpgCheck.exitCode == 0) {
          final output = gpgCheck.stdout as String;
          if (output.trim().isNotEmpty) {
            final keyCount = RegExp(r'sec\s+').allMatches(output).length;
            print('GPG available with $keyCount secret key(s)');
          } else {
            print('GPG available but no secret keys');
          }
        } else {
          print('GPG command failed: ${gpgCheck.stderr}');
        }
      } catch (e) {
        print('GPG not available: $e');
      }
    });
  });

  group('Git MCP Server Simulation', () {
    late Directory tempDir;
    late Directory repoDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('git_mcp_sim_test_');
      repoDir = Directory(p.join(tempDir.path, 'test_repo'));
      await repoDir.create();
      
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git', ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('simulates commit with sign="none"', () async {
      final testFile = File(p.join(repoDir.path, 'test.dart'));
      await testFile.writeAsString('void main() {}\n');

      var result = await Process.run(
        'git', ['add', 'test.dart'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0);

      // Simulates sign="none" which uses --no-gpg-sign
      result = await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'Unsigned commit'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      
      expect(result.exitCode, 0, reason: 'Commit failed: ${result.stderr}');

      result = await Process.run(
        'git', ['log', '--oneline'],
        workingDirectory: repoDir.path,
      );
      expect(result.stdout, contains('Unsigned commit'));
    });

    test('simulates commit with sign="ssh" using temp key', () async {
      // Create temp SSH key for this test (not in $HOME/.ssh!)
      final sshDir = Directory(p.join(tempDir.path, 'ssh'));
      await sshDir.create();
      final sshKeyPath = p.join(sshDir.path, 'id_ed25519');
      
      // Check git version
      final gitVersion = await Process.run('git', ['--version']);
      final versionStr = (gitVersion.stdout as String).trim();
      final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(versionStr);
      if (match == null) {
        markTestSkipped('Could not parse git version');
        return;
      }
      
      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);
      if (major < 2 || (major == 2 && minor < 34)) {
        markTestSkipped('Git version too old for SSH signing');
        return;
      }
      
      // Generate temp key
      final keygenResult = await Process.run(
        'ssh-keygen',
        ['-t', 'ed25519', '-f', sshKeyPath, '-N', '', '-C', 'test@example.com'],
      );
      if (keygenResult.exitCode != 0) {
        markTestSkipped('Could not generate SSH key');
        return;
      }
      
      final testFile = File(p.join(repoDir.path, 'ssh_test.dart'));
      await testFile.writeAsString('// SSH signed\n');

      var result = await Process.run(
        'git', ['add', 'ssh_test.dart'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0);

      // Simulates sign="ssh" which uses -c options
      result = await Process.run(
        'git',
        [
          '-c', 'gpg.format=ssh',
          '-c', 'user.signingkey=$sshKeyPath.pub',
          'commit', '-S', '-m', 'SSH signed via simulation'
        ],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      
      print('SSH simulation stdout: ${result.stdout}');
      print('SSH simulation stderr: ${result.stderr}');
      
      expect(result.exitCode, 0, reason: 'SSH-signed commit failed: ${result.stderr}');

      result = await Process.run(
        'git', ['log', '--oneline'],
        workingDirectory: repoDir.path,
      );
      expect(result.stdout, contains('SSH signed via simulation'));
    });
  });

  group('Monorepo layout (git root != project dir)', () {
    late Directory tempDir;
    late Directory repoDir;
    late Directory subProjectDir;
    late String subLibDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('git_mcp_monorepo_int_');
      repoDir = Directory(p.join(tempDir.path, 'repo'));
      subProjectDir = Directory(p.join(repoDir.path, 'packages', 'sub'));
      subLibDir = p.join(subProjectDir.path, 'lib');

      // Create monorepo structure
      await Directory(subLibDir).create(recursive: true);

      // git init at repo root
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run('git', ['config', 'user.email', 'test@example.com'],
          workingDirectory: repoDir.path);
      await Process.run('git', ['config', 'user.name', 'Test User'],
          workingDirectory: repoDir.path);

      // Create an out-of-scope file at repo root
      await File(p.join(repoDir.path, 'README.md'))
          .writeAsString('# Monorepo');

      // Create a file inside sub-project
      await File(p.join(subLibDir, 'foo.dart'))
          .writeAsString('void foo() {}');

      // Initial commit with all files
      await Process.run('git', ['add', '.'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'initial'],
        workingDirectory: repoDir.path,
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('findGitRoot returns repo root from sub-project', () {
      final result = findGitRoot(subProjectDir.path);
      expect(result, equals(p.normalize(repoDir.path)));
    });

    test('status succeeds from sub-project', () async {
      // Modify a file so status has something to show
      await File(p.join(subLibDir, 'foo.dart'))
          .writeAsString('void foo() { /* changed */ }');

      final gitOps = GitOperations(
        workingDir: repoDir,
        projectDir: subProjectDir,
        allowedPaths: [subLibDir],
      );

      final result = await gitOps.status();
      final text = (result.content.first as TextContent).text;
      expect(text, contains('packages/sub/lib/foo.dart'));
    });

    test('add explicit file and commit from sub-project', () async {
      // Modify file
      await File(p.join(subLibDir, 'foo.dart'))
          .writeAsString('void foo() { /* v2 */ }');

      final gitOps = GitOperations(
        workingDir: repoDir,
        projectDir: subProjectDir,
        allowedPaths: [subLibDir],
      );
      final signingInfo = await detectSigningCapabilities();
      final commitOps = CommitOperations(
        workingDir: repoDir,
        signingInfo: signingInfo,
      );

      // Stage via relative path (resolved against projectDir)
      var result = await gitOps.add(['lib/foo.dart']);
      var text = (result.content.first as TextContent).text;
      expect(text, contains('Staged'));

      // Verify via git that the correct file is staged
      final diffResult = await Process.run(
        'git', ['diff', '--cached', '--name-only'],
        workingDirectory: repoDir.path,
      );
      expect(diffResult.stdout, contains('packages/sub/lib/foo.dart'));

      // Commit
      result = await commitOps.commit('Add sub foo', sign: 'none');
      text = (result.content.first as TextContent).text;
      expect(text, contains('Add sub foo'));

      // Verify commit in log
      final logResult = await Process.run(
        'git', ['log', '--oneline'],
        workingDirectory: repoDir.path,
      );
      expect(logResult.stdout, contains('Add sub foo'));
    });

    test('add --all only stages files within sub-project', () async {
      // Modify file inside sub-project
      await File(p.join(subLibDir, 'foo.dart'))
          .writeAsString('void foo() { /* v3 */ }');

      // Modify file outside sub-project
      await File(p.join(repoDir.path, 'README.md'))
          .writeAsString('# Monorepo updated');

      final gitOps = GitOperations(
        workingDir: repoDir,
        projectDir: subProjectDir,
        allowedPaths: [subLibDir],
      );

      final result = await gitOps.add(null, all: true);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Staged 1 file(s)'));
      expect(text, contains('Skipped (outside allowed paths)'));
      expect(text, contains('README.md'));
    });

    test('diff works from sub-project', () async {
      // Modify file
      await File(p.join(subLibDir, 'foo.dart'))
          .writeAsString('void foo() { /* diffed */ }');

      final gitOps = GitOperations(
        workingDir: repoDir,
        projectDir: subProjectDir,
        allowedPaths: [subLibDir],
      );

      final result = await gitOps.diff();
      final text = (result.content.first as TextContent).text;
      expect(text, contains('foo.dart'));
      expect(text, contains('diffed'));
    });

    test('findGitRoot returns null when no .git exists', () {
      final noGitDir = p.join(tempDir.path, 'no_repo', 'sub');
      Directory(noGitDir).createSync(recursive: true);

      // Use stopAt to avoid walking above tempDir
      final result = findGitRoot(noGitDir, stopAt: tempDir.path);
      expect(result, isNull);
    });
  });
}
