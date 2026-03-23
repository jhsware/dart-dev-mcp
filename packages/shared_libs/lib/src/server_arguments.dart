import 'dart:io';
import 'package:path/path.dart' as p;

/// Represents parsed server command-line arguments for MCP servers.
///
/// Supports multi-project sessions where each MCP server can operate
/// across multiple projects. Database paths are inferred from a shared
/// `--planner-data-root` directory.
///
/// Usage:
/// ```dart
/// final args = ServerArguments.parse(arguments);
/// final dbPath = args.plannerDbPath('/path/to/project');
/// ```
class ServerArguments {
  /// All project directories provided via --project-dir (normalized to absolute paths).
  final List<String> projectDirs;

  /// Root directory for planner data (--planner-data-root).
  /// DB paths are inferred as: [plannerDataRoot]/projects/[dir-name]/db/planner.db
  final String? plannerDataRoot;

  /// Path to prompts file (--prompts-file, optional, planner only).
  final String? promptsFilePath;

  /// Whether help was requested via --help or -h.
  final bool helpRequested;

  /// Any unrecognized arguments (not --project-dir, --planner-data-root, etc.).
  final List<String> unknownArguments;

  ServerArguments({
    required this.projectDirs,
    this.plannerDataRoot,
    this.promptsFilePath,
    this.helpRequested = false,
    this.unknownArguments = const [],
  });

  /// Infer planner DB path for a given project directory.
  ///
  /// Returns: `[plannerDataRoot]/projects/[basename(projectDir)]/db/planner.db`
  /// Throws [StateError] if [plannerDataRoot] is null.
  String plannerDbPath(String projectDir) {
    if (plannerDataRoot == null) {
      throw StateError('plannerDataRoot must be set to infer DB paths');
    }
    final projectName = p.basename(projectDir);
    return p.join(
        plannerDataRoot!, 'projects', projectName, 'db', 'planner.db');
  }

  /// Infer code_index DB path for a given project directory.
  ///
  /// Returns: `[plannerDataRoot]/projects/[basename(projectDir)]/db/code_index.db`
  /// Throws [StateError] if [plannerDataRoot] is null.
  String codeIndexDbPath(String projectDir) {
    if (plannerDataRoot == null) {
      throw StateError('plannerDataRoot must be set to infer DB paths');
    }
    final projectName = p.basename(projectDir);
    return p.join(
        plannerDataRoot!, 'projects', projectName, 'db', 'code_index.db');
  }

  /// Parse server arguments from command-line arguments list.
  ///
  /// Supports both `--flag=value` and `--flag value` formats.
  factory ServerArguments.parse(List<String> arguments) {
    final projectDirs = <String>[];
    String? plannerDataRoot;
    String? promptsFilePath;
    bool helpRequested = false;
    final unknownArguments = <String>[];

    for (int i = 0; i < arguments.length; i++) {
      final arg = arguments[i];

      if (arg == '--help' || arg == '-h') {
        helpRequested = true;
      } else if (arg.startsWith('--project-dir=')) {
        final value = arg.substring('--project-dir='.length);
        if (value.isNotEmpty) {
          projectDirs.add(_normalizeToAbsolutePath(value));
        }
      } else if (arg == '--project-dir' && i + 1 < arguments.length) {
        final value = arguments[++i];
        if (value.isNotEmpty && !value.startsWith('--')) {
          projectDirs.add(_normalizeToAbsolutePath(value));
        } else {
          i--;
          unknownArguments.add(arg);
        }
      } else if (arg.startsWith('--planner-data-root=')) {
        final value = arg.substring('--planner-data-root='.length);
        if (value.isNotEmpty) {
          plannerDataRoot = _normalizeToAbsolutePath(value);
        }
      } else if (arg == '--planner-data-root' && i + 1 < arguments.length) {
        final value = arguments[++i];
        if (value.isNotEmpty && !value.startsWith('--')) {
          plannerDataRoot = _normalizeToAbsolutePath(value);
        } else {
          i--;
          unknownArguments.add(arg);
        }
      } else if (arg.startsWith('--prompts-file=')) {
        final value = arg.substring('--prompts-file='.length);
        if (value.isNotEmpty) {
          promptsFilePath = _normalizeToAbsolutePath(value);
        }
      } else if (arg == '--prompts-file' && i + 1 < arguments.length) {
        final value = arguments[++i];
        if (value.isNotEmpty && !value.startsWith('--')) {
          promptsFilePath = _normalizeToAbsolutePath(value);
        } else {
          i--;
          unknownArguments.add(arg);
        }
      } else {
        unknownArguments.add(arg);
      }
    }

    return ServerArguments(
      projectDirs: projectDirs,
      plannerDataRoot: plannerDataRoot,
      promptsFilePath: promptsFilePath,
      helpRequested: helpRequested,
      unknownArguments: unknownArguments,
    );
  }

  /// Normalize a path to absolute (handles ~, relative paths).
  static String _normalizeToAbsolutePath(String inputPath) {
    String expandedPath = inputPath;
    if (inputPath.startsWith('~')) {
      final home = Platform.environment['HOME'] ?? '';
      expandedPath = inputPath.replaceFirst('~', home);
    }
    return p.normalize(p.absolute(expandedPath));
  }

  @override
  String toString() {
    return 'ServerArguments('
        'projectDirs: $projectDirs, '
        'plannerDataRoot: $plannerDataRoot, '
        'promptsFilePath: $promptsFilePath, '
        'helpRequested: $helpRequested, '
        'unknownArguments: $unknownArguments)';
  }
}
