import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Integration tests for git operations including SSH and GPG signing
/// 
/// These tests create real temporary git repositories and test operations.
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
      
      // Generate a test SSH key (no passphrase)
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
      
      // Create a test GPG key (no passphrase)
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

    test('simulates commit with sign="ssh" (if SSH key exists)', () async {
      // Check for SSH key
      final home = Platform.environment['HOME'];
      String? sshKeyPath;
      
      for (final path in ['$home/.ssh/id_ed25519.pub', '$home/.ssh/id_ecdsa.pub', '$home/.ssh/id_rsa.pub']) {
        if (await File(path).exists()) {
          sshKeyPath = path;
          break;
        }
      }
      
      if (sshKeyPath == null) {
        markTestSkipped('No SSH key found');
        return;
      }
      
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
          '-c', 'user.signingkey=$sshKeyPath',
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
}
