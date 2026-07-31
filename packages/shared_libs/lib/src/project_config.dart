import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The preferred name of the project configuration file.
const String configFileName = 'jhsware_code.yaml';

/// Legacy configuration file name, still accepted so existing projects
/// keep working without changes.
const String legacyConfigFileName = 'jhsware-code.yaml';

/// Accepted configuration file names in lookup order. When both files
/// exist, the preferred name wins.
const List<String> configFileNames = [configFileName, legacyConfigFileName];

/// Holds parsed configuration from a project configuration file
/// (jhsware_code.yaml or the legacy jhsware-code.yaml).
///
/// Maps MCP tool names to lists of relative paths that tool is allowed to
/// access. Tool keys are stored in canonical form: hyphens replaced with
/// underscores. Hyphen and underscore spellings are interchangeable: a
/// `code_index:` entry matches the `code-index` tool and the other way around.
class ProjectConfig {
  /// Canonical tool name → list of relative paths (as specified in the YAML file).
  final Map<String, List<String>> toolPaths;

  const ProjectConfig(this.toolPaths);

  /// An empty config that represents "no config file found".
  static const ProjectConfig empty = ProjectConfig({});

  /// Whether this config was loaded from an actual file (non-empty toolPaths).
  bool get hasConfig => toolPaths.isNotEmpty;
}

/// Cache entry holding a parsed config plus the source file identity used
/// for invalidation (path and modification time).
class _CacheEntry {
  final String configPath;
  final DateTime modTime;
  final ProjectConfig config;

  _CacheEntry(this.configPath, this.modTime, this.config);
}

/// Service for loading and caching project configuration from
/// jhsware_code.yaml (or the legacy jhsware-code.yaml).
///
/// Each MCP tool can call [getAllowedPaths] with a project root and tool name
/// to get a list of absolute paths it is allowed to access.
///
/// Behavior:
/// - If no config file exists: returns `[projectRoot]` (full access).
/// - If the tool name is not in the config: returns `[projectRoot]` (full access).
/// - If the tool name is in the config with an empty list: returns `[]` (no access).
/// - Otherwise: returns the resolved absolute paths for that tool.
///
/// Tool names are matched in canonical form (hyphens replaced with
/// underscores), so hyphen and underscore spellings are interchangeable: a
/// `code_index:` key matches the `code-index` tool and the other way around.
///
/// Results are cached per project root and invalidated when the config
/// file's path or modification time changes.
class ProjectConfigService {
  /// Internal cache keyed by absolute project root path.
  static final Map<String, _CacheEntry> _cache = {};

  /// Clears the internal cache. Useful for testing.
  static void clearCache() {
    _cache.clear();
  }

  /// Canonical form of a tool name or config key: hyphens become underscores.
  static String canonicalToolName(String name) => name.replaceAll('-', '_');

  /// Returns the first existing config file for [projectRoot], or null.
  static File? _findConfigFile(String projectRoot) {
    for (final name in configFileNames) {
      final file = File(p.join(projectRoot, name));
      if (file.existsSync()) {
        return file;
      }
    }
    return null;
  }

  /// Loads and parses the config for [projectRoot].
  ///
  /// Looks for `jhsware_code.yaml` first, then the legacy
  /// `jhsware-code.yaml`. Returns [ProjectConfig.empty] if neither exists.
  /// Throws [FormatException] if the YAML is malformed or has unexpected
  /// structure.
  static ProjectConfig loadConfig(String projectRoot) {
    final configFile = _findConfigFile(projectRoot);

    if (configFile == null) {
      return ProjectConfig.empty;
    }

    final modTime = configFile.lastModifiedSync();
    final absRoot = p.normalize(p.absolute(projectRoot));

    // Check cache
    final cached = _cache[absRoot];
    if (cached != null &&
        cached.configPath == configFile.path &&
        cached.modTime == modTime) {
      return cached.config;
    }

    // Parse
    final content = configFile.readAsStringSync();
    final config = _parseYaml(content, p.basename(configFile.path));

    // Cache
    _cache[absRoot] = _CacheEntry(configFile.path, modTime, config);

    return config;
  }

  /// Returns the list of absolute allowed paths for [toolName] in [projectRoot].
  ///
  /// - If no config file exists, returns `[projectRoot]` (full access).
  /// - If [toolName] is not listed in the config, returns `[projectRoot]` (full access).
  /// - If [toolName] has an empty list, returns `[]` (no access).
  /// - Otherwise, resolves relative paths to absolute and returns them.
  static List<String> getAllowedPaths(String projectRoot, String toolName) {
    final absRoot = p.normalize(p.absolute(projectRoot));
    final config = loadConfig(projectRoot);

    if (!config.hasConfig) {
      // No config file — full project access
      return [absRoot];
    }

    final key = canonicalToolName(toolName);
    if (!config.toolPaths.containsKey(key)) {
      // Tool not mentioned in config — full project access
      return [absRoot];
    }

    final relativePaths = config.toolPaths[key]!;
    if (relativePaths.isEmpty) {
      // Explicitly empty — no access
      return [];
    }

    // Resolve relative paths to absolute
    return relativePaths.map((relPath) {
      return p.normalize(p.join(absRoot, relPath));
    }).toList();
  }

  /// Parses YAML content into a [ProjectConfig].
  ///
  /// Expects a YAML map where each key is a tool name and each value is a
  /// list of strings. Keys are stored in canonical form (hyphens replaced
  /// with underscores).
  static ProjectConfig _parseYaml(String content, String fileName) {
    final dynamic yaml;
    try {
      yaml = loadYaml(content);
    } catch (e) {
      throw FormatException('Failed to parse $fileName: $e');
    }

    if (yaml == null) {
      // Empty YAML file
      return ProjectConfig.empty;
    }

    if (yaml is! YamlMap) {
      throw FormatException(
        'Invalid $fileName: expected a YAML map at the top level, '
        'got ${yaml.runtimeType}',
      );
    }

    final toolPaths = <String, List<String>>{};

    for (final entry in yaml.entries) {
      final key = entry.key;
      if (key is! String) {
        throw FormatException(
          'Invalid $fileName: expected string key, got ${key.runtimeType} ($key)',
        );
      }

      final value = entry.value;
      if (value == null) {
        // Tool listed with no paths — no access
        toolPaths[canonicalToolName(key)] = [];
        continue;
      }

      if (value is! YamlList) {
        throw FormatException(
          'Invalid $fileName: expected a list for key "$key", '
          'got ${value.runtimeType}',
        );
      }

      final paths = <String>[];
      for (final item in value) {
        if (item is! String) {
          throw FormatException(
            'Invalid $fileName: expected string path in list for "$key", '
            'got ${item.runtimeType} ($item)',
          );
        }
        paths.add(item);
      }
      toolPaths[canonicalToolName(key)] = paths;
    }

    return ProjectConfig(toolPaths);
  }
}
