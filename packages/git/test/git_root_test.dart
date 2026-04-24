import 'dart:io';

import 'package:git_mcp/git_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('findGitRoot', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('git_root_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('finds .git directory at startDir', () {
      final repoDir = tempDir.path;
      Directory(p.join(repoDir, '.git')).createSync();

      expect(findGitRoot(repoDir), equals(p.normalize(repoDir)));
    });

    test('finds .git one parent up (monorepo sub-project)', () {
      final repoDir = p.join(tempDir.path, 'repo');
      Directory(p.join(repoDir, '.git')).createSync(recursive: true);
      final subProject = p.join(repoDir, 'packages', 'sub');
      Directory(subProject).createSync(recursive: true);

      expect(findGitRoot(subProject), equals(p.normalize(repoDir)));
    });

    test('finds .git several levels up', () {
      final repoDir = p.join(tempDir.path, 'repo');
      Directory(p.join(repoDir, '.git')).createSync(recursive: true);
      final deepDir = p.join(repoDir, 'packages', 'sub', 'deep', 'nested');
      Directory(deepDir).createSync(recursive: true);

      expect(findGitRoot(deepDir), equals(p.normalize(repoDir)));
    });

    test('returns null when no .git exists up to boundary', () {
      final noGitDir = p.join(tempDir.path, 'no_repo', 'sub');
      Directory(noGitDir).createSync(recursive: true);

      // Use stopAt to prevent walking above tempDir (which might find
      // a real .git on the test machine)
      expect(findGitRoot(noGitDir, stopAt: tempDir.path), isNull);
    });

    test('treats .git as valid when it is a file (worktree/submodule)', () {
      final repoDir = p.join(tempDir.path, 'repo');
      Directory(repoDir).createSync();
      // Submodules and worktrees use a .git file pointing to the real git dir
      File(p.join(repoDir, '.git'))
          .writeAsStringSync('gitdir: /elsewhere/.git/worktrees/repo');
      final subProject = p.join(repoDir, 'packages', 'sub');
      Directory(subProject).createSync(recursive: true);

      expect(findGitRoot(subProject), equals(p.normalize(repoDir)));
    });

    test('handles trailing separator in input', () {
      final repoDir = p.join(tempDir.path, 'repo');
      Directory(p.join(repoDir, '.git')).createSync(recursive: true);

      final withTrailing = '$repoDir/';
      final result = findGitRoot(withTrailing);
      // p.normalize strips trailing separators
      expect(result, equals(p.normalize(repoDir)));
      expect(result!.endsWith('/'), isFalse);
    });

    test('handles non-normalized input path', () {
      final repoDir = p.join(tempDir.path, 'repo');
      Directory(p.join(repoDir, '.git')).createSync(recursive: true);
      final subProject = p.join(repoDir, 'packages', 'sub');
      Directory(subProject).createSync(recursive: true);

      // Pass a path with ../ segments
      final nonNormalized = p.join(repoDir, 'packages', 'sub', '..', 'sub');
      expect(findGitRoot(nonNormalized), equals(p.normalize(repoDir)));
    });
  });
}
