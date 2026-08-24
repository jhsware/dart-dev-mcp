import 'dart:io';

import 'package:jhsware_code_git/git_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Tests for the remote-list operation.
///
/// Creates real temporary git repositories and verifies that remotes are
/// parsed from `git remote -v` into name + URL pairs, that fetch/push
/// roles are deduplicated when identical and labeled when they differ,
/// and that the operation works from a worktree directory.
void main() {
  group('remote-list', () {
    late Directory tempDir;
    late Directory repoDir;

    Future<void> git(List<String> args, {Directory? cwd}) async {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: (cwd ?? repoDir).path,
        environment: Platform.environment,
      );
      expect(
        result.exitCode,
        0,
        reason: 'git ${args.join(" ")} failed: ${result.stderr}',
      );
    }

    GitOperations opsFor(Directory dir) => GitOperations(
      workingDir: dir,
      projectDir: dir,
      allowedPaths: [dir.path],
    );

    Future<String> remoteListText(Directory dir) async {
      final result = await opsFor(dir).remoteList();
      return (result.content.first as TextContent).text;
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('git_remote_test_');
      repoDir = Directory(p.join(tempDir.path, 'test_repo'));
      await repoDir.create();
      await git(['init']);
      await git(['config', 'user.email', 'test@example.com']);
      await git(['config', 'user.name', 'Test User']);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('returns "No remotes" for a repo without remotes', () async {
      final text = await remoteListText(repoDir);
      expect(text, 'No remotes');
    });

    test(
      'lists a remote once when fetch and push URLs are identical',
      () async {
        await git(['remote', 'add', 'origin', 'git@example.com:user/repo.git']);

        final text = await remoteListText(repoDir);
        expect(text, 'origin\tgit@example.com:user/repo.git');
      },
    );

    test('lists multiple remotes', () async {
      await git(['remote', 'add', 'origin', 'git@example.com:user/repo.git']);
      await git([
        'remote',
        'add',
        'upstream',
        'https://example.com/other/repo.git',
      ]);

      final text = await remoteListText(repoDir);
      expect(text, contains('origin\tgit@example.com:user/repo.git'));
      expect(text, contains('upstream\thttps://example.com/other/repo.git'));
    });

    test('labels fetch and push roles when the URLs differ', () async {
      await git(['remote', 'add', 'origin', 'git@example.com:user/repo.git']);
      await git([
        'remote',
        'set-url',
        '--push',
        'origin',
        'git@example.com:user/push-repo.git',
      ]);

      final text = await remoteListText(repoDir);
      expect(text, contains('origin\tgit@example.com:user/repo.git (fetch)'));
      expect(
        text,
        contains('origin\tgit@example.com:user/push-repo.git (push)'),
      );
    });

    test('works when invoked from a worktree directory', () async {
      await git(['remote', 'add', 'origin', 'git@example.com:user/repo.git']);

      // A worktree needs at least one commit
      final testFile = File(p.join(repoDir.path, 'test.txt'));
      await testFile.writeAsString('Hello, World!\n');
      await git(['add', 'test.txt']);
      await git(['commit', '--no-gpg-sign', '-m', 'Initial commit']);

      // Provision a worktree the way builder_server does:
      // <repo>/.worktrees/<branch-slug>
      final worktreeDir = Directory(
        p.join(repoDir.path, '.worktrees', 'my-branch'),
      );
      await git(['worktree', 'add', worktreeDir.path, '-b', 'my-branch']);

      final text = await remoteListText(worktreeDir);
      expect(text, 'origin\tgit@example.com:user/repo.git');
    });
  });
}
