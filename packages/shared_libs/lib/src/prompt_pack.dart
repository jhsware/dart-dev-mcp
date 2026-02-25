import 'package:yaml/yaml.dart';

/// A template with variable placeholders that can be rendered with values.
///
/// Templates use `{{variable}}` syntax for placeholder substitution.
/// Variables that are not provided during rendering are left as-is.
class PromptTemplate {
  /// The raw template string with `{{variable}}` placeholders.
  final String template;

  /// List of variable names used in the template.
  final List<String> variables;

  PromptTemplate({required this.template, required this.variables});

  /// Creates a [PromptTemplate] from a map (typically parsed from YAML).
  ///
  /// Expected keys: `template` (String), `variables` (List<String>).
  factory PromptTemplate.fromMap(Map<String, dynamic> map) {
    final template = map['template'] as String? ?? '';
    final variables = (map['variables'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    return PromptTemplate(template: template, variables: variables);
  }

  /// Renders the template by substituting `{{key}}` placeholders with values.
  ///
  /// Unknown variables (not in [values]) are left as-is in the output.
  String render(Map<String, String> values) {
    var result = template;
    for (final entry in values.entries) {
      result = result.replaceAll('{{${entry.key}}}', entry.value);
    }
    return result;
  }
}

/// A collection of named prompt templates.
///
/// A PromptPack can be loaded from a YAML string or created with defaults.
/// It supports looking up templates by name and rendering them with variables.
class PromptPack {
  /// Map of template name to [PromptTemplate].
  final Map<String, PromptTemplate> templates;

  PromptPack({required this.templates});

  /// Parses a [PromptPack] from a YAML string.
  ///
  /// Expected YAML structure:
  /// ```yaml
  /// templates:
  ///   template_name:
  ///     template: |
  ///       Some text with {{variable}}
  ///     variables:
  ///       - variable
  /// ```
  factory PromptPack.fromYamlString(String yamlString) {
    final doc = loadYaml(yamlString);
    if (doc is! YamlMap) {
      return PromptPack(templates: {});
    }

    final templatesMap = doc['templates'];
    if (templatesMap is! YamlMap) {
      return PromptPack(templates: {});
    }

    final templates = <String, PromptTemplate>{};
    for (final entry in templatesMap.entries) {
      final name = entry.key.toString();
      final value = entry.value;
      if (value is YamlMap) {
        final map = <String, dynamic>{
          'template': value['template']?.toString() ?? '',
          'variables': (value['variables'] as YamlList?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [],
        };
        templates[name] = PromptTemplate.fromMap(map);
      }
    }

    return PromptPack(templates: templates);
  }

  /// Returns the template with the given [name], or `null` if not found.
  PromptTemplate? getTemplate(String name) => templates[name];

  /// Returns `true` if a template with the given [name] exists.
  bool hasTemplate(String name) => templates.containsKey(name);

  /// Renders a template by [name] with the given [values].
  ///
  /// Throws [ArgumentError] if the template is not found.
  String renderTemplate(String name, Map<String, String> values) {
    final template = templates[name];
    if (template == null) {
      throw ArgumentError('Template not found: $name');
    }
    return template.render(values);
  }

  /// Creates a [PromptPack] with the default templates for the planner.
  ///
  /// Includes:
  /// - `copy_task_prompt` — for regular sub-tasks
  /// - `copy_parent_task_prompt` — for parent sub-tasks (title starts with "Parent:")
  factory PromptPack.defaults() {
    return PromptPack(templates: {
      'copy_task_prompt': PromptTemplate(
        template: _defaultTaskPrompt,
        variables: _commonVariables,
      ),
      'copy_parent_task_prompt': PromptTemplate(
        template: _defaultParentTaskPrompt,
        variables: _commonVariables,
      ),
    });
  }

  static const _commonVariables = [
    'task_id',
    'task_title',
    'task_details',
    'task_status',
    'project_id',
    'steps',
  ];

  static const _defaultTaskPrompt = '''Task ID: {{task_id}}
Task: {{task_title}}
{{task_details}}
Steps:
{{steps}}
Implement this task. Use planner (dart-dev-mcp-planner) to find the task and steps. Start by updating the task status to started. Double check that the step hasn't been completed by another task. When working on a step first change step status to started.
- Use show-task in planner to understand how we have progressed so far.
- Summarise progress in task memory and update planner as you progress, especially if the step is complex, both updating status of steps and task memory as needed so it is easy to continue if we get interrupted.
- Commit each step to git, and commit sub steps to git too if appropriate.
- Analyse code using filesystem tool to further understand how to complete the task.
- Edit files using filesystem tool.
- Do not work in a sandbox, the filesystem tool has restricted access.
IMPORTANT! Use skill /planner-do-sub-task to perform this task.
Go.''';

  static const _defaultParentTaskPrompt = '''Task ID: {{task_id}}
Task: {{task_title}}
{{task_details}}
Steps:
{{steps}}
Implement this task. Use planner (dart-dev-mcp-planner) to find the task and steps. Start by updating the task status to started. Double check that the step hasn't been completed by another task. When working on a step first change step status to started.
- Use show-task in planner to understand how we have progressed so far.
- Summarise progress in task memory and update planner as you progress, especially if the step is complex, both updating status of steps and task memory as needed so it is easy to continue if we get interrupted.
- Commit each step to git, and commit sub steps to git too if appropriate.
- Analyse code using filesystem tool to further understand how to complete the task.
- Edit files using filesystem tool.
- Do not work in a sandbox, the filesystem tool has restricted access.
IMPORTANT! Use skill /planner-do-sub-task to perform this task.
Go.''';
}
