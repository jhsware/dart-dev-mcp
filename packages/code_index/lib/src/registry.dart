import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'storage_paths.dart';

/// Central registry (`<dataRoot>/registry.json`) and per-project marker
/// (`<dataDir>/meta.json`) management for the v2 store (design §3.2/§3.3).

/// Current on-disk `registry.json` format version.
const int registryFormatVersion = 1;

/// Basename of the per-project metadata marker file.
const String metaFileName = 'meta.json';

/// Basename of the central registry file.
const String registryFileName = 'registry.json';

/// Thrown when an existing `meta.json` describes a different project than the
/// one being opened — guards against hash-prefix collisions and manual
/// directory shuffling (design §3.3).
class MetaMismatchError extends StateError {
  MetaMismatchError(super.message);
}

String _nowIso() => DateTime.now().toUtc().toIso8601String();

/// Read and parse `registry.json`, returning an empty registry map when the
/// file is missing or corrupt (rebuilt lazily on the next write).
Map<String, dynamic> _readRegistry(String dataRoot) {
  final file = File(p.join(dataRoot, registryFileName));
  if (!file.existsSync()) {
    return {'version': registryFormatVersion, 'projects': <String, dynamic>{}};
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic> && decoded['projects'] is Map) {
      return decoded;
    }
  } catch (_) {
    // Corrupt registry — fall through to a fresh one.
  }
  return {'version': registryFormatVersion, 'projects': <String, dynamic>{}};
}

/// Atomically write [registry] to `registry.json` (write `.tmp`, then rename).
void _writeRegistryAtomic(String dataRoot, Map<String, dynamic> registry) {
  Directory(dataRoot).createSync(recursive: true);
  final target = File(p.join(dataRoot, registryFileName));
  final tmp = File(p.join(dataRoot, '$registryFileName.tmp'));
  tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(registry));
  tmp.renameSync(target.path);
}

/// Insert or update the registry entry for [projectPath]. Sets `dir` and
/// `name`, stamps `created_at` once, and refreshes `last_opened_at` on every
/// call. The registry is rebuilt lazily when missing or corrupt.
void upsertProject(String dataRoot, String projectPath) {
  final canonical = canonicalProjectPath(projectPath);
  final registry = _readRegistry(dataRoot);
  final projects = (registry['projects'] as Map).cast<String, dynamic>();
  final now = _nowIso();

  final existing = projects[canonical];
  final createdAt = (existing is Map && existing['created_at'] is String)
      ? existing['created_at'] as String
      : now;

  projects[canonical] = <String, dynamic>{
    'dir': dataDirNameFor(canonical),
    'name': p.basename(canonical),
    'created_at': createdAt,
    'last_opened_at': now,
  };

  registry['version'] = registryFormatVersion;
  registry['projects'] = projects;
  _writeRegistryAtomic(dataRoot, registry);
}

/// Write the per-project `meta.json` marker into [dataDir].
void writeMeta(String dataDir, String projectPath, int schemaVersion) {
  final canonical = canonicalProjectPath(projectPath);
  final file = File(p.join(dataDir, metaFileName));
  final meta = <String, dynamic>{
    'project_path': canonical,
    'project_name': p.basename(canonical),
    'schema_version': schemaVersion,
    'created_at': _nowIso(),
  };
  Directory(dataDir).createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(meta));
}

/// Read the per-project `meta.json` marker, or null when absent/corrupt.
Map<String, dynamic>? readMeta(String dataDir) {
  final file = File(p.join(dataDir, metaFileName));
  if (!file.existsSync()) {
    return null;
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } catch (_) {
    // Corrupt marker — treat as absent.
  }
  return null;
}

/// Verify that any existing `meta.json` in [dataDir] belongs to
/// [projectPath]. Throws [MetaMismatchError] on mismatch. A missing marker is
/// allowed (a fresh directory).
void assertMetaMatches(String dataDir, String projectPath) {
  final meta = readMeta(dataDir);
  if (meta == null) {
    return;
  }
  final stored = meta['project_path'];
  final canonical = canonicalProjectPath(projectPath);
  if (stored is String && stored != canonical) {
    throw MetaMismatchError(
      'Data directory "$dataDir" belongs to project "$stored", '
      'not "$canonical". Refusing to open.',
    );
  }
}

/// Scan [dataRoot] for store directories whose recorded source project no
/// longer exists on disk (orphans left behind by merged worktree families,
/// deleted projects, and the like).
///
/// Only directories with a readable `meta.json` recording `project_path`
/// can be identified; directories without one are reported as
/// `unidentified` and never touched. With [delete] false (the default)
/// this is a dry run that only reports. With [delete] true the orphaned
/// store directories are removed together with their `registry.json`
/// entries.
Map<String, dynamic> pruneOrphanedStores(
  String dataRoot, {
  bool delete = false,
}) {
  final root = Directory(dataRoot);
  final orphans = <Map<String, dynamic>>[];
  final unidentified = <String>[];
  var keptCount = 0;

  if (root.existsSync()) {
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final meta = readMeta(entity.path);
      final projectPath = meta?['project_path'];
      if (projectPath is! String) {
        unidentified.add(p.basename(entity.path));
        continue;
      }
      if (Directory(projectPath).existsSync()) {
        keptCount++;
        continue;
      }
      orphans.add({
        'dir': p.basename(entity.path),
        'project_path': projectPath,
      });
      if (delete) {
        entity.deleteSync(recursive: true);
      }
    }
  }

  if (delete && orphans.isNotEmpty) {
    _removeRegistryEntries(
      dataRoot,
      orphans.map((o) => o['project_path'] as String).toSet(),
    );
  }

  return {
    'deleted': delete,
    'orphans': orphans,
    'kept_count': keptCount,
    'unidentified': unidentified,
  };
}

/// Drop registry entries whose canonical project path is in [projectPaths].
void _removeRegistryEntries(String dataRoot, Set<String> projectPaths) {
  final registry = _readRegistry(dataRoot);
  final projects = (registry['projects'] as Map).cast<String, dynamic>();
  projects.removeWhere((path, _) => projectPaths.contains(path));
  registry['projects'] = projects;
  _writeRegistryAtomic(dataRoot, registry);
}
