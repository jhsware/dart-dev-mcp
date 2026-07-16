import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:test/test.dart';

void main() {
  group('resolveProjectDirAlias', () {
    const repo = '/Users/dev/business-app/jhsware_business';
    const worktree =
        '/Users/dev/business-app/jhsware_business/.worktrees/orchestration-fix-123';

    test('exact match returns the registered dir', () {
      expect(resolveProjectDirAlias(repo, [repo]), equals(repo));
      expect(resolveProjectDirAlias(worktree, [worktree]), equals(worktree));
    });

    test('exact match is path-normalized (trailing slash)', () {
      expect(resolveProjectDirAlias('$repo/', [repo]), equals(repo));
    });

    test('repository dir resolves to its registered worktree', () {
      expect(resolveProjectDirAlias(repo, [worktree]), equals(worktree));
    });

    test('worktree dir resolves to its registered repository', () {
      expect(resolveProjectDirAlias(worktree, [repo]), equals(repo));
    });

    test('path inside a worktree resolves to its registered repository', () {
      expect(
        resolveProjectDirAlias('$worktree/packages/mcp', [repo]),
        equals(repo),
      );
    });

    test('exact match wins when both repo and worktree are registered', () {
      expect(
          resolveProjectDirAlias(repo, [worktree, repo]), equals(repo));
      expect(resolveProjectDirAlias(worktree, [repo, worktree]),
          equals(worktree));
    });

    test('ambiguous repo→worktree alias is rejected', () {
      const secondWorktree =
          '/Users/dev/business-app/jhsware_business/.worktrees/task-other-456';
      expect(
        resolveProjectDirAlias(repo, [worktree, secondWorktree]),
        isNull,
      );
    });

    test('unrelated dir does not resolve', () {
      expect(
        resolveProjectDirAlias('/Users/dev/other-project', [repo, worktree]),
        isNull,
      );
    });

    test('sibling of .worktrees does not resolve to the repository', () {
      expect(
        resolveProjectDirAlias('$repo/packages/mcp', [repo]),
        isNull,
      );
    });

    test('a repo whose name prefixes another does not match', () {
      // `/a/repo2` must not be treated as inside `/a/repo/.worktrees`.
      expect(
        resolveProjectDirAlias(
            '$repo/.worktrees-backup/x', [repo]),
        isNull,
      );
    });

    test('empty input returns null', () {
      expect(resolveProjectDirAlias('', [repo]), isNull);
    });

    test('empty registered list returns null', () {
      expect(resolveProjectDirAlias(repo, []), isNull);
    });
  });
}
