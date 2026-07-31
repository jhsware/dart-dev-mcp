/// Resolution of caller-supplied `project_dir` values against the
/// registered `--project-dir` list, with git-worktree aliasing.
library;

import 'package:path/path.dart' as p;

/// Name of the directory (directly under a repository root) that holds
/// server-provisioned git worktrees.
///
/// Must match `WorktreeManager.worktreesDirName` in builder_server, which
/// provisions worktrees at `<repoRoot>/.worktrees/<branch-slug>`.
const String worktreesDirName = '.worktrees';

/// Map a path inside a provisioned worktree back to its repository-side
/// counterpart.
///
/// A worktree checks out the **whole** repository at
/// `<root>/.worktrees/<branch-slug>`, so any path of the form
/// `<root>/.worktrees/<slug>/<rest>` corresponds to `<root>/<rest>` in the
/// main working tree (`<rest>` may be empty: the checkout root maps to the
/// repository root). This also covers projects that are sub-folders of a
/// shared repository: `<root>/.worktrees/<slug>/my_project` maps to
/// `<root>/my_project`.
///
/// Returns the canonical repository-side path, or null when [path] does not
/// contain a `.worktrees/<slug>` segment pair — i.e. it is already a
/// repository-side path. Matching is segment-exact: `.worktrees-backup`
/// does not match.
String? stripWorktreeInfix(String path) {
  final segments = p.split(p.normalize(p.absolute(path)));
  final idx = segments.indexOf(worktreesDirName);
  // Need `<root>/.worktrees/<slug>`: `.worktrees` must not be the first
  // segment and a slug segment must follow it.
  if (idx < 1 || idx + 1 >= segments.length) return null;
  return p.joinAll([...segments.sublist(0, idx), ...segments.sublist(idx + 2)]);
}

/// Resolve a caller-supplied [requested] project directory against the
/// registered [projectDirs], accepting worktree aliases.
///
/// Sessions that run in a provisioned git worktree register different
/// `--project-dir` values per MCP server: the planner MCP registers the
/// original project directory (planner_server resolves projects by
/// directory basename), while the filesystem / git / runner / code-index
/// MCPs register the project's checkout inside the worktree —
/// `<root>/.worktrees/<slug>` when the project is the repository root, or
/// `<root>/.worktrees/<slug>/<project>` when the project is a sub-folder
/// of a shared repository. The agent only knows one directory at a time
/// and cannot tell which spelling a given server expects, so each server
/// accepts both spellings and maps them to its own registered one:
///
/// - Exact match (path-normalized) → that registered dir.
/// - [requested] is a repository-side path and exactly one registered dir
///   is its worktree counterpart (its infix-stripped form equals
///   [requested]) → that registered dir.
/// - [requested] is a worktree-side path (contains `.worktrees/<slug>`):
///   1. a registered worktree-side dir that contains it → that dir;
///   2. exactly one registered dir *inside* it (e.g. [requested] is the
///      checkout root and the project is a sub-folder) → that dir;
///   3. the registered repository-side dir that equals or contains its
///      infix-stripped form → that dir.
///
/// Always returns the matching entry from [projectDirs] (never the raw
/// input), so downstream lookups — `jhsware_code.yaml` allowed paths, DB
/// paths keyed on basename, git roots — behave exactly as if the caller
/// had passed the registered value.
///
/// Returns null when nothing matches, or when the repository→worktree
/// direction is ambiguous (more than one registered worktree counterpart
/// of the same directory).
String? resolveProjectDirAlias(String requested, List<String> projectDirs) {
  if (requested.isEmpty) return null;
  final normalized = p.normalize(p.absolute(requested));

  // Exact match wins.
  for (final dir in projectDirs) {
    if (p.equals(dir, normalized)) return dir;
  }

  final requestedCanonical = stripWorktreeInfix(normalized);

  if (requestedCanonical == null) {
    // Repository-side path. Its worktree counterpart may be registered:
    // a registered dir whose infix-stripped form equals the request.
    final counterparts = <String>[];
    for (final dir in projectDirs) {
      final stripped = stripWorktreeInfix(dir);
      if (stripped != null && p.equals(stripped, normalized)) {
        counterparts.add(dir);
      }
    }
    if (counterparts.length == 1) return counterparts.first;
    return null; // none, or ambiguous — refuse to guess
  }

  // Worktree-side path. Prefer a registered worktree-side dir that
  // literally contains it: same checkout, no guessing involved.
  for (final dir in projectDirs) {
    if (stripWorktreeInfix(dir) != null && p.isWithin(dir, normalized)) {
      return dir;
    }
  }

  // The request may sit *above* the registered dir in the same checkout —
  // e.g. the checkout root while the registered project is a sub-folder.
  final within = <String>[];
  for (final dir in projectDirs) {
    if (p.isWithin(normalized, dir)) within.add(dir);
  }
  if (within.length == 1) return within.first;
  if (within.length > 1) return null; // ambiguous — refuse to guess

  // Otherwise the repository-side registration: the registered dir that
  // equals or contains the canonical (infix-stripped) form.
  for (final dir in projectDirs) {
    if (stripWorktreeInfix(dir) != null) continue;
    if (p.equals(dir, requestedCanonical) ||
        p.isWithin(dir, requestedCanonical)) {
      return dir;
    }
  }

  return null;
}
