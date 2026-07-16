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

  group('resolveProjectDirAlias — sub-folder projects (shared repo)', () {
    // A project that is a sub-folder of a shared git repository. The
    // worktree checks out the whole repo, so the project's files live at
    // the same repo-relative path inside the checkout.
    const root = '/Users/dev/agentic-coding/builder';
    const project = '$root/builder_server';
    const sibling = '$root/builder_app';
    const checkout = '$root/.worktrees/fix-foo-123';
    const wtProject = '$checkout/builder_server';

    test('project dir resolves to its registered worktree counterpart', () {
      expect(resolveProjectDirAlias(project, [wtProject]), equals(wtProject));
    });

    test('worktree counterpart resolves to the registered project dir', () {
      expect(resolveProjectDirAlias(wtProject, [project]), equals(project));
    });

    test('path inside the worktree project resolves to the registered '
        'project dir', () {
      expect(
        resolveProjectDirAlias('$wtProject/lib/src', [project]),
        equals(project),
      );
    });

    test('path inside the registered worktree project dir resolves to it',
        () {
      expect(
        resolveProjectDirAlias('$wtProject/lib/src', [wtProject]),
        equals(wtProject),
      );
    });

    test('checkout root resolves to the single registered project dir '
        'inside it', () {
      expect(resolveProjectDirAlias(checkout, [wtProject]),
          equals(wtProject));
    });

    test('checkout root with two registered projects inside is ambiguous',
        () {
      const wtSibling = '$checkout/builder_app';
      expect(
        resolveProjectDirAlias(checkout, [wtProject, wtSibling]),
        isNull,
      );
    });

    test('a sibling project in the same worktree does not alias', () {
      expect(
        resolveProjectDirAlias('$checkout/builder_app', [project]),
        isNull,
      );
    });

    test('a worktree of another branch still resolves to the registered '
        'project dir', () {
      expect(
        resolveProjectDirAlias(
            '$root/.worktrees/task-bar-456/builder_server', [project]),
        equals(project),
      );
    });

    test('ambiguous project→worktree counterpart is rejected', () {
      const otherCheckout = '$root/.worktrees/task-bar-456/builder_server';
      expect(
        resolveProjectDirAlias(project, [wtProject, otherCheckout]),
        isNull,
      );
    });

    test('the repository root does not resolve to a sub-folder project '
        'worktree', () {
      expect(resolveProjectDirAlias(root, [wtProject]), isNull);
    });

    test('sibling project dirs never alias each other', () {
      expect(resolveProjectDirAlias(sibling, [project]), isNull);
      expect(
        resolveProjectDirAlias('$checkout/builder_app', [wtProject]),
        isNull,
      );
    });
  });

  group('stripWorktreeInfix', () {
    test('maps a checkout root to the repository root', () {
      expect(
        stripWorktreeInfix('/a/repo/.worktrees/slug'),
        equals('/a/repo'),
      );
    });

    test('maps a path inside a checkout to its repo-side counterpart', () {
      expect(
        stripWorktreeInfix('/a/repo/.worktrees/slug/pkg/lib'),
        equals('/a/repo/pkg/lib'),
      );
    });

    test('returns null for a repository-side path', () {
      expect(stripWorktreeInfix('/a/repo/pkg/lib'), isNull);
    });

    test('matching is segment-exact', () {
      expect(stripWorktreeInfix('/a/repo/.worktrees-backup/x'), isNull);
    });

    test('returns null when .worktrees is the last segment', () {
      expect(stripWorktreeInfix('/a/repo/.worktrees'), isNull);
    });

    test('normalizes the input (trailing slash)', () {
      expect(
        stripWorktreeInfix('/a/repo/.worktrees/slug/'),
        equals('/a/repo'),
      );
    });
  });
}
