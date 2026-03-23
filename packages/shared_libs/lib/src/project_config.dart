import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The name of the project configuration file.
const String configFileName = 'jhsware-code.yaml';

/// Holds parsed configuration from a jhsware-code.yaml file.
///
/// Maps MCP tool names to lists of relative paths that tool is allowed to access.
class ProjectConfig {
  /// Tool name → list of relative paths (as specified in the YAML file).
  final Map<String, List<String>> toolPaths;

  const ProjectConfig(this.toolPaths);

  /// An empty config that represents "no config file found".
  static const ProjectConfig empty = ProjectConfig({});

  /// Whether this config was loaded from an actual file (non-empty toolPaths).
  bool get hasConfig => toolPaths.isNotEmpty;
}

/// Cache entry holding a parsed config and the file modification time.
class _CacheEntry {
  final DateTime modTime;
  final ProjectConfig config;

  _CacheEntry(this.modTime, this.config);
}

/// Service for loading and caching project configuration from jhsware-code.yaml.
///
/// Each MCP tool can call [getAllowedPaths] with a project root and tool name
/// to get a list of absolute paths it is allowed to access.
///
/// Behavior:
/// - If jhsware-code.yaml does not exist: returns `[projectRoot]` (full access).
/// - If the tool name is not in the config: returns `[projectRoot]` (full access).
/// - If the tool name is in the config with an empty list: returns `[]` (no access).
/// - Otherwise: returns the resolved absolute paths for that tool.
///
/// Results are cached per project root and invalidated when the file's
/// modification time changes.
class ProjectConfigService {
  /// Internal cache keyed by absolute project root path.
  static final Map<String, _CacheEntry> _cache = {};

  /// Clears the internal cache. Useful for testing.
  static void clearCache() {
    _cache.clear();
  }

  /// Loads and parses the config from `<projectRoot>/jhsware-code.yaml`.
  ///
  /// Returns [ProjectConfig.empty] if the file does not exist.
  /// Throws [FormatException] if the YAML is malformed or has unexpected structure.
  static ProjectConfig loadConfig(String projectRoot) {
    final configFile = File(p.join(projectRoot, configFileName));

    if (!configFile.existsSync()) {
      return ProjectConfig.empty;
    }

    final modTime = configFile.lastModifiedSync();
    final absRoot = p.normalize(p.absolute(projectRoot));

    // Check cache
    final cached = _cache[absRoot];
    if (cached != null && cached.modTime == modTime) {
      return cached.config;
    }

    // Parse
    final content = configFile.readAsStringSync();
    final config = _parseYaml(content);

    // Cache
    _cache[absRoot] = _CacheEntry(modTime, config);

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

    if (!config.toolPaths.containsKey(toolName)) {
      // Tool not mentioned in config — full project access
      return [absRoot];
    }

    final relativePaths = config.toolPaths[toolName]!;
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
  /// Expects a YAML map where each key is a tool name and each value is a list of strings.
  static ProjectConfig _parseYaml(String content) {
    final dynamic yaml;
    try {
      yaml = loadYaml(content);
    } catch (e) {
      throw FormatException(
        'Failed to parse $configFileName: $e',
      );
    }

    if (yaml == null) {
      // Empty YAML file
      return ProjectConfig.empty;
    }

    if (yaml is! YamlMap) {
      throw FormatException(
        'Invalid $configFileName: expected a YAML map at the top level, '
        'got ${yaml.runtimeType}',
      );
    }

    final toolPaths = <String, List<String>>{};

    for (final entry in yaml.entries) {
      final key = entry.key;
      if (key is! String) {
        throw FormatException(
          'Invalid $configFileName: expected string key, got ${key.runtimeType} ($key)',
        );
      }

      final value = entry.value;
      if (value == null) {
        // Tool listed with no paths — no access
        toolPaths[key] = [];
        continue;
      }

      if (value is! YamlList) {
        throw FormatException(
          'Invalid $configFileName: expected a list for key "$key", '
          'got ${value.runtimeType}',
        );
      }

      final paths = <String>[];
      for (final item in value) {
        if (item is! String) {
          throw FormatException(
            'Invalid $configFileName: expected string path in list for "$key", '
            'got ${item.runtimeType} ($item)',
          );
        }
        paths.add(item);
      }
      toolPaths[key] = paths;
    }

    return ProjectConfig(toolPaths);
  }
}
