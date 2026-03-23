import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('prompt_pack_service_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('PromptPackService initialization', () {
    test('initializes with defaults when no file path given', () {
      final service = PromptPackService();
      service.initialize();
      addTearDown(service.dispose);

      expect(service.promptPack.hasTemplate('copy_task_prompt'), isTrue);
      expect(
          service.promptPack.hasTemplate('copy_parent_task_prompt'), isTrue);
    });

    test('falls back to defaults when file does not exist', () {
      final service = PromptPackService(
        promptsFilePath: '${tempDir.path}/nonexistent.yaml',
      );
      service.initialize();
      addTearDown(service.dispose);

      expect(service.promptPack.hasTemplate('copy_task_prompt'), isTrue);
      expect(
          service.promptPack.hasTemplate('copy_parent_task_prompt'), isTrue);
    });

    test('loads templates from YAML file when path provided', () {
      final yamlFile = File('${tempDir.path}/prompts.yaml');
      yamlFile.writeAsStringSync('''
templates:
  custom_template:
    template: "Custom: {{value}}"
    variables:
      - value
''');

      final service = PromptPackService(
        promptsFilePath: yamlFile.path,
      );
      service.initialize();
      addTearDown(service.dispose);

      expect(service.promptPack.hasTemplate('custom_template'), isTrue);
      // Defaults should still be present
      expect(service.promptPack.hasTemplate('copy_task_prompt'), isTrue);
      expect(
          service.promptPack.hasTemplate('copy_parent_task_prompt'), isTrue);
    });

    test('merges file templates with defaults (file overrides)', () {
      final yamlFile = File('${tempDir.path}/prompts.yaml');
      yamlFile.writeAsStringSync('''
templates:
  copy_task_prompt:
    template: "Overridden: {{task_title}}"
    variables:
      - task_title
''');

      final service = PromptPackService(
        promptsFilePath: yamlFile.path,
      );
      service.initialize();
      addTearDown(service.dispose);

      // Overridden template
      final tmpl = service.promptPack.getTemplate('copy_task_prompt')!;
      expect(tmpl.template, 'Overridden: {{task_title}}');

      // Default still present for the other template
      expect(
          service.promptPack.hasTemplate('copy_parent_task_prompt'), isTrue);
    });

    test('falls back to defaults when YAML is malformed', () {
      final yamlFile = File('${tempDir.path}/bad.yaml');
      yamlFile.writeAsStringSync(': : : invalid yaml [[[');

      final service = PromptPackService(
        promptsFilePath: yamlFile.path,
      );
      service.initialize();
      addTearDown(service.dispose);

      // Should fall back to defaults
      expect(service.promptPack.hasTemplate('copy_task_prompt'), isTrue);
    });
  });

  group('renderSubtaskPrompt', () {
    late PromptPackService service;

    setUp(() {
      service = PromptPackService();
      service.initialize();
    });

    tearDown(() {
      service.dispose();
    });

    Map<String, dynamic> makeTask({
      String id = 'task-1',
      String title = 'Test Task',
      String details = 'Task details here',
      String status = 'started',
    }) {
      return {
        'id': id,
        'title': title,
        'details': details,
        'status': status,
      };
    }

    List<Map<String, dynamic>> makeSteps() {
      return [
        {
          'id': 'step-1',
          'title': 'First step',
          'details': 'Do the first thing',
          'status': 'done',
          'sub_task_id': null,
        },
        {
          'id': 'step-2',
          'title': 'Second step',
          'details': '',
          'status': 'todo',
          'sub_task_id': 'sub-task-99',
        },
      ];
    }

    test('uses copy_task_prompt for regular tasks', () {
      final result = service.renderSubtaskPrompt(
        task: makeTask(title: 'Regular Task'),
        steps: makeSteps(),
      );
      // Should contain the regular task instructions, not parent task
      expect(result, contains('Regular Task'));
      expect(result, contains('planner-do-task'));
      expect(result, isNot(contains('PARENT TASK')));
    });

    test('uses copy_parent_task_prompt for parent tasks', () {
      final result = service.renderSubtaskPrompt(
        task: makeTask(title: 'Parent: My Parent Task'),
        steps: makeSteps(),
      );
      expect(result, contains('Parent: My Parent Task'));
      expect(result, contains('PARENT TASK'));
      expect(result, contains('get-subtask-prompt'));
      expect(result, contains('planner-do-parent-task'));
    });

    test('substitutes all template variables', () {
      final result = service.renderSubtaskPrompt(
        task: makeTask(
          id: 'tid-42',
          title: 'Build feature X',
          details: 'Detailed description of feature X',
          status: 'todo',
        ),
        steps: [],
      );
      expect(result, contains('tid-42'));
      expect(result, contains('Build feature X'));
      expect(result, contains('Detailed description of feature X'));
      // No unresolved variables
      expect(result, isNot(contains('{{task_id}}')));
      expect(result, isNot(contains('{{task_title}}')));
      expect(result, isNot(contains('{{task_details}}')));
      expect(result, isNot(contains('{{steps}}')));
    });

    test('formats steps into readable numbered list', () {
      final result = service.renderSubtaskPrompt(
        task: makeTask(),
        steps: makeSteps(),
      );
      // Step 1 with details
      expect(result, contains('1.'));
      expect(result, contains('id: step-1'));
      expect(result, contains('title: First step'));
      expect(result, contains('details: Do the first thing'));
      expect(result, contains('status: done'));

      // Step 2 without details (empty string), with sub_task_id
      expect(result, contains('2.'));
      expect(result, contains('id: step-2'));
      expect(result, contains('title: Second step'));
      expect(result, contains('sub_task_id: sub-task-99'));
    });

    test('formats steps without details correctly', () {
      final steps = [
        {
          'id': 's1',
          'title': 'No details step',
          'details': '',
          'status': 'todo',
          'sub_task_id': null,
        },
      ];
      final result = service.renderSubtaskPrompt(
        task: makeTask(),
        steps: steps,
      );
      // Should not include 'details:' since details is empty
      expect(result, isNot(contains('details: ')));
      expect(result, contains('sub_task_id: none'));
    });

    test('handles empty steps list', () {
      final result = service.renderSubtaskPrompt(
        task: makeTask(),
        steps: [],
      );
      // Should still render without error
      expect(result, contains('task-1'));
      expect(result, contains('Test Task'));
    });

    test('handles task with null/missing fields gracefully', () {
      final task = <String, dynamic>{
        'id': null,
        'title': null,
      };
      // Should not throw, uses empty string defaults
      final result = service.renderSubtaskPrompt(
        task: task,
        steps: [],
      );
      expect(result, isA<String>());
    });
  });

  group('PromptPackService with custom file templates', () {
    test('renderSubtaskPrompt uses overridden template from file', () {
      final tempDir2 =
          Directory.systemTemp.createTempSync('prompt_custom_test_');
      addTearDown(() => tempDir2.deleteSync(recursive: true));

      final yamlFile = File('${tempDir2.path}/prompts.yaml');
      yamlFile.writeAsStringSync('''
templates:
  copy_task_prompt:
    template: |
      CUSTOM PROMPT for {{task_title}} ({{task_id}})
      Steps: {{steps}}
    variables:
      - task_title
      - task_id
      - steps
''');

      final service = PromptPackService(
        promptsFilePath: yamlFile.path,
      );
      service.initialize();
      addTearDown(service.dispose);

      final result = service.renderSubtaskPrompt(
        task: {
          'id': 'x1',
          'title': 'Custom Task',
          'details': 'details',
          'status': 'todo',
        },
        steps: [],
      );
      expect(result, contains('CUSTOM PROMPT for Custom Task (x1)'));
    });
  });
}
