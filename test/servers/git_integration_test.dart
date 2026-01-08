import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Integration tests for git operations
/// These tests create a real temporary git repository and test operations
void main() {
  group('Git Integration Tests', () {
    late Directory tempDir;
    late Directory repoDir;

    setUp(() async {
      // Create a unique temporary directory for each test
      tempDir = await Directory.systemTemp.createTemp('git_mcp_test_');
      repoDir = Directory(p.join(tempDir.path, 'test_repo'));
      await repoDir.create();
    });

    tearDown(() async {
      // Clean up the temporary directory
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('can init, add, and commit without SSH/GPG agent', () async {
      // 1. Initialize git repository
      var result = await Process.run(
        'git',
        ['init'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0, reason: 'git init failed: ${result.stderr}');

      // 2. Configure local git user (required for commits)
      result = await Process.run(
        'git',
        ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0, reason: 'git config email failed: ${result.stderr}');

      result = await Process.run(
        'git',
        ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0, reason: 'git config name failed: ${result.stderr}');

      // 3. Disable GPG signing for this repo (in case it's enabled globally)
      result = await Process.run(
        'git',
        ['config', 'commit.gpgsign', 'false'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0, reason: 'git config gpgsign failed: ${result.stderr}');

      // 4. Create a test file
      final testFile = File(p.join(repoDir.path, 'test.txt'));
      await testFile.writeAsString('Hello, World!\n');
      expect(await testFile.exists(), isTrue);

      // 5. Stage the file
      result = await Process.run(
        'git',
        ['add', 'test.txt'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0, reason: 'git add failed: ${result.stderr}');

      // 6. Commit the file
      result = await Process.run(
        'git',
        ['commit', '-m', 'Initial commit'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0, reason: 'git commit failed: ${result.stderr}');

      // 7. Verify the commit exists
      result = await Process.run(
        'git',
        ['log', '--oneline'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0, reason: 'git log failed: ${result.stderr}');
      expect(result.stdout, contains('Initial commit'));
    });

    test('can commit with explicit no-gpg-sign flag', () async {
      // Initialize and configure
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run(
        'git',
        ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git',
        ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
      );

      // Create and stage file
      final testFile = File(p.join(repoDir.path, 'test.txt'));
      await testFile.writeAsString('Test content\n');
      await Process.run('git', ['add', '.'], workingDirectory: repoDir.path);

      // Commit with --no-gpg-sign flag
      final result = await Process.run(
        'git',
        ['commit', '--no-gpg-sign', '-m', 'Test commit without GPG'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      
      expect(result.exitCode, 0, reason: 'git commit --no-gpg-sign failed: ${result.stderr}');
      
      // Verify
      final logResult = await Process.run(
        'git',
        ['log', '--oneline'],
        workingDirectory: repoDir.path,
      );
      expect(logResult.stdout, contains('Test commit without GPG'));
    });

    test('commit fails gracefully when GPG agent is unavailable but signing is required', () async {
      // Initialize and configure
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run(
        'git',
        ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git',
        ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
      );
      
      // Force GPG signing (this should fail without gpg-agent)
      await Process.run(
        'git',
        ['config', 'commit.gpgsign', 'true'],
        workingDirectory: repoDir.path,
      );
      // Set a dummy key that won't exist
      await Process.run(
        'git',
        ['config', 'user.signingkey', 'NONEXISTENT_KEY'],
        workingDirectory: repoDir.path,
      );

      // Create and stage file
      final testFile = File(p.join(repoDir.path, 'test.txt'));
      await testFile.writeAsString('Test content\n');
      await Process.run('git', ['add', '.'], workingDirectory: repoDir.path);

      // This commit should fail due to GPG issues
      final result = await Process.run(
        'git',
        ['commit', '-m', 'This should fail'],
        workingDirectory: repoDir.path,
        // Explicitly clear GPG-related env vars
        environment: {
          ...Platform.environment,
          'GPG_AGENT_INFO': '',
          'GPG_TTY': '',
        },
      );
      
      // We expect this to fail
      expect(result.exitCode, isNot(0), reason: 'Expected commit to fail when GPG signing is required but agent unavailable');
    });

    test('environment variables are passed to subprocess', () async {
      // This test verifies that environment variables are actually passed
      final result = await Process.run(
        'env',
        [],
        environment: {
          ...Platform.environment,
          'TEST_VAR': 'test_value_12345',
        },
      );
      
      expect(result.stdout, contains('TEST_VAR=test_value_12345'));
    });

    test('Platform.environment contains expected variables', () {
      // Debug: print what's in Platform.environment
      print('Platform.environment keys: ${Platform.environment.keys.toList()}');
      print('HOME: ${Platform.environment['HOME']}');
      print('PATH: ${Platform.environment['PATH']?.substring(0, 50)}...');
      print('SSH_AUTH_SOCK: ${Platform.environment['SSH_AUTH_SOCK']}');
      print('GPG_AGENT_INFO: ${Platform.environment['GPG_AGENT_INFO']}');
      
      // HOME and PATH should always be present
      expect(Platform.environment['HOME'], isNotNull);
      expect(Platform.environment['PATH'], isNotNull);
    });
  });

  group('Git MCP Server Integration', () {
    late Directory tempDir;
    late Directory repoDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('git_mcp_server_test_');
      repoDir = Directory(p.join(tempDir.path, 'test_repo'));
      await repoDir.create();
      
      // Initialize repo with config
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run(
        'git',
        ['config', 'user.email', 'test@example.com'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git',
        ['config', 'user.name', 'Test User'],
        workingDirectory: repoDir.path,
      );
      await Process.run(
        'git',
        ['config', 'commit.gpgsign', 'false'],
        workingDirectory: repoDir.path,
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('simulates git_mcp commit operation with --no-gpg-sign', () async {
      // Create a file
      final testFile = File(p.join(repoDir.path, 'lib', 'test.dart'));
      await testFile.parent.create(recursive: true);
      await testFile.writeAsString('void main() {}\n');

      // Stage the file (simulating _add)
      var result = await Process.run(
        'git',
        ['add', 'lib/test.dart'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      expect(result.exitCode, 0);

      // Commit with --no-gpg-sign (simulating updated _commit in git_mcp.dart)
      result = await Process.run(
        'git',
        ['commit', '--no-gpg-sign', '-m', 'Add test.dart'],
        workingDirectory: repoDir.path,
        environment: Platform.environment,
      );
      
      print('Commit stdout: ${result.stdout}');
      print('Commit stderr: ${result.stderr}');
      print('Commit exitCode: ${result.exitCode}');
      
      expect(result.exitCode, 0, reason: 'git commit failed: ${result.stderr}');

      // Verify
      result = await Process.run(
        'git',
        ['log', '--oneline'],
        workingDirectory: repoDir.path,
      );
      expect(result.stdout, contains('Add test.dart'));
    });

    test('commit works in restricted environment (no SSH/GPG agent)', () async {
      // This simulates the MCP server environment where SSH_AUTH_SOCK and GPG vars may not be set
      
      // Create a file
      final testFile = File(p.join(repoDir.path, 'src', 'main.dart'));
      await testFile.parent.create(recursive: true);
      await testFile.writeAsString('void main() => print("Hello");\n');

      // Create a minimal environment without SSH/GPG agent sockets
      final restrictedEnv = <String, String>{
        'HOME': Platform.environment['HOME'] ?? '/tmp',
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'USER': Platform.environment['USER'] ?? 'test',
        // Explicitly NOT including SSH_AUTH_SOCK, GPG_AGENT_INFO, GPG_TTY
      };

      // Stage the file
      var result = await Process.run(
        'git',
        ['add', 'src/main.dart'],
        workingDirectory: repoDir.path,
        environment: restrictedEnv,
      );
      expect(result.exitCode, 0, reason: 'git add failed: ${result.stderr}');

      // Commit with --no-gpg-sign in restricted environment
      result = await Process.run(
        'git',
        ['commit', '--no-gpg-sign', '-m', 'Add main.dart in restricted env'],
        workingDirectory: repoDir.path,
        environment: restrictedEnv,
      );
      
      print('Restricted env commit stdout: ${result.stdout}');
      print('Restricted env commit stderr: ${result.stderr}');
      print('Restricted env commit exitCode: ${result.exitCode}');
      
      expect(result.exitCode, 0, reason: 'git commit in restricted env failed: ${result.stderr}');

      // Verify
      result = await Process.run(
        'git',
        ['log', '--oneline'],
        workingDirectory: repoDir.path,
      );
      expect(result.stdout, contains('Add main.dart'));
    });
  });
}
