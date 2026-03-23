import 'dart:async';
import 'dart:io';

import 'logging.dart';
import 'prompt_pack.dart';

/// Service that manages prompt templates with file-based loading and watching.
///
/// Loads prompt templates from a YAML file, watches for changes with
/// debouncing, and falls back to defaults if the file is missing or invalid.
///
/// Usage:
/// ```dart
/// final service = PromptPackService(promptsFilePath: '/path/to/prompts.yaml');
/// service.initialize();
/// final prompt = service.renderSubtaskPrompt(task: taskMap, steps: stepsList);
/// // ...
/// service.dispose();
/// ```
class PromptPackService {
  /// Path to the prompts YAML file, or `null` to use defaults only.
  final String? promptsFilePath;

  /// The current prompt pack (merged defaults + file overrides).
  PromptPack _promptPack;

  /// File watcher subscription.
  StreamSubscription<FileSystemEvent>? _watcherSubscription;

  /// Debounce timer for file change detection.
  Timer? _debounceTimer;

  /// Fallback poll timer to detect changes missed by file watcher.
  Timer? _pollTimer;

  /// Last known modification time for poll-based change detection.
  DateTime? _lastModified;

  /// Debounce duration for file change detection.
  static const _debounceDuration = Duration(milliseconds: 500);

  /// Poll interval for fallback change detection.
  static const _pollInterval = Duration(seconds: 30);

  /// Creates a [PromptPackService].
  ///
  /// If [promptsFilePath] is provided, the service will attempt to load
  /// templates from that YAML file during [initialize]. Templates from the
  /// file override defaults; missing templates fall back to defaults.
  PromptPackService({this.promptsFilePath})
      : _promptPack = PromptPack.defaults();

  /// The current prompt pack.
  PromptPack get promptPack => _promptPack;

  /// Initializes the service by loading prompts from file and setting up
  /// file watching.
  ///
  /// If [promptsFilePath] is `null` or the file doesn't exist, defaults
  /// are used. File watching is set up if the file exists.
  void initialize() {
    if (promptsFilePath == null) {
      logInfo('prompt-pack', 'No prompts file path configured, using defaults');
      return;
    }

    _loadPrompts();
    _setupFileWatching();
  }

  /// Loads prompts from the YAML file and merges with defaults.
  void _loadPrompts() {
    if (promptsFilePath == null) return;

    final file = File(promptsFilePath!);
    if (!file.existsSync()) {
      logWarning('prompt-pack',
          'Prompts file not found: $promptsFilePath, using defaults');
      _promptPack = PromptPack.defaults();
      return;
    }

    try {
      final content = file.readAsStringSync();
      final filePack = PromptPack.fromYamlString(content);
      _promptPack = _mergeWithDefaults(filePack);
      _lastModified = file.lastModifiedSync();
      logInfo('prompt-pack',
          'Loaded ${filePack.templates.length} templates from $promptsFilePath');
    } catch (e) {
      logWarning('prompt-pack',
          'Failed to parse prompts file: $promptsFilePath ($e), using defaults');
      _promptPack = PromptPack.defaults();
    }
  }

  /// Merges file-loaded templates with defaults.
  ///
  /// File templates take priority. Default templates that are not present
  /// in the file are included as fallbacks.
  PromptPack _mergeWithDefaults(PromptPack filePack) {
    final defaults = PromptPack.defaults();
    final merged = <String, PromptTemplate>{};

    // Start with defaults
    merged.addAll(defaults.templates);

    // Override with file templates
    merged.addAll(filePack.templates);

    return PromptPack(templates: merged);
  }

  /// Sets up file watching with debounce and fallback polling.
  void _setupFileWatching() {
    if (promptsFilePath == null) return;

    final file = File(promptsFilePath!);

    // Set up File.watch() for real-time change detection
    try {
      _watcherSubscription = file.watch().listen(
        (event) {
          _onFileChanged();
        },
        onError: (error) {
          logWarning(
              'prompt-pack', 'File watcher error: $error, relying on polling');
        },
      );
    } catch (e) {
      logWarning(
          'prompt-pack', 'Could not set up file watcher: $e, relying on polling');
    }

    // Set up fallback poll timer
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      _checkFileModified();
    });
  }

  /// Handles file change events with debouncing.
  void _onFileChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, () {
      logInfo('prompt-pack', 'Reloading prompts after file change');
      _loadPrompts();
    });
  }

  /// Polls the file modification time as a fallback for missed watcher events.
  void _checkFileModified() {
    if (promptsFilePath == null) return;

    final file = File(promptsFilePath!);
    if (!file.existsSync()) return;

    try {
      final modified = file.lastModifiedSync();
      if (_lastModified != null && modified.isAfter(_lastModified!)) {
        logInfo('prompt-pack', 'Detected file change via polling');
        _loadPrompts();
      }
    } catch (e) {
      // Ignore poll errors silently
    }
  }

  /// Renders a prompt for a sub-task.
  ///
  /// Selects the appropriate template based on whether the task title
  /// starts with "Parent:" and renders it with the task's data.
  ///
  /// [task] should contain keys: `id`, `title`, `details`, `status`.
  /// [steps] should be a list of maps with keys: `id`, `title`, `details`, `status`, `sub_task_id`.
  String renderSubtaskPrompt({
    required Map<String, dynamic> task,
    required List<Map<String, dynamic>> steps,
  }) {
    final title = task['title'] as String? ?? '';
    final isParentTask = title.startsWith('Parent:');
    final templateName =
        isParentTask ? 'copy_parent_task_prompt' : 'copy_task_prompt';

    // Format steps into a readable numbered list
    final formattedSteps = _formatSteps(steps);

    // Build variables map
    final variables = <String, String>{
      'task_id': task['id']?.toString() ?? '',
      'task_title': title,
      'task_details': task['details']?.toString() ?? '',
      'task_status': task['status']?.toString() ?? '',
      'steps': formattedSteps,
    };

    return _promptPack.renderTemplate(templateName, variables);
  }

  /// Formats a list of steps into a readable numbered list.
  String _formatSteps(List<Map<String, dynamic>> steps) {
    final buffer = StringBuffer();
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final parts = <String>[
        'id: ${step['id'] ?? 'unknown'}',
        'title: ${step['title'] ?? 'untitled'}',
      ];
      if (step['details'] != null &&
          (step['details'] as String).isNotEmpty) {
        parts.add('details: ${step['details']}');
      }
      parts.add('status: ${step['status'] ?? 'unknown'}');
      if (step['sub_task_id'] != null) {
        parts.add('sub_task_id: ${step['sub_task_id']}');
      } else {
        parts.add('sub_task_id: none');
      }
      buffer.writeln('${i + 1}. ${parts.join(', ')}');
    }
    return buffer.toString().trimRight();
  }

  /// Disposes of file watchers and timers.
  ///
  /// Call this when the service is no longer needed to free resources.
  void dispose() {
    _watcherSubscription?.cancel();
    _watcherSubscription = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}
