/// Resolution of caller-supplied `project_dir` values against the
/// registered `--project-dir` list, with git-worktree aliasing.
library;

import 'package:path/path.dart' as p;

/// Name of the directory (directly under a repository root) that holds
/// server-provisioned git worktrees.
///
/// Must match `WorktreeManager.worktreesDirName` in builder_server, which
/// provisions worktrees at `<repo>/.worktrees/<branch-slug>`.
const String worktreesDirName = '.worktrees';

/// Resolve a caller-supplied [requested] project directory against the
/// registered [projectDirs], accepting worktree aliases.
///
/// Sessions that run in a provisioned git worktree register different
/// `--project-dir` values per MCP server: the planner MCP registers the
/// original repository (planner_server resolves projects by directory
/// basename), while the filesystem / git / runner / code-index MCPs
/// register the worktree (`<repo>/.worktrees/<branch-slug>`) where the
/// agent's files live. The agent only knows one directory at a time and
/// cannot tell which spelling a given server expects, so each server
/// accepts both spellings and maps them to its own registered one:
///
/// - Exact match (path-normalized) → that registered dir.
/// - [requested] is a repository and exactly one registered dir lies
///   inside `<requested>/.worktrees/` → that worktree.
/// - [requested] lies inside `<registered>/.worktrees/` → that registered
///   repository.
///
/// Always returns the matching entry from [projectDirs] (never the raw
/// input), so downstream lookups — `jhsware-code.yaml` allowed paths, DB
/// paths keyed on basename, git roots — behave exactly as if the caller
/// had passed the registered value.
///
/// Returns null when nothing matches, or when the repository→worktree
/// direction is ambiguous (more than one registered worktree of the same
/// repository).
String? resolveProjectDirAlias(String requested, List<String> projectDirs) {
  if (requested.isEmpty) return null;
  final normalized = p.normalize(p.absolute(requested));

  // Exact match wins.
  for (final dir in projectDirs) {
    if (p.equals(dir, normalized)) return dir;
  }

  // Requested the repository; its provisioned worktree is registered.
  final worktreesRoot = p.join(normalized, worktreesDirName);
  final worktreeMatches =
      projectDirs.where((dir) => p.isWithin(worktreesRoot, dir)).toList();
  if (worktreeMatches.length == 1) return worktreeMatches.first;
  if (worktreeMatches.length > 1) return null; // ambiguous — refuse to guess

  // Requested a worktree (or a path inside one); its repository is
  // registered.
  for (final dir in projectDirs) {
    if (p.isWithin(p.join(dir, worktreesDirName), normalized)) return dir;
  }

  return null;
}
