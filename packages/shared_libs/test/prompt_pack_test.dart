import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:test/test.dart';

void main() {
  group('PromptTemplate', () {
    test('fromMap parses template and variables', () {
      final map = {
        'template': 'Hello {{name}}, welcome to {{place}}!',
        'variables': ['name', 'place'],
      };
      final tmpl = PromptTemplate.fromMap(map);
      expect(tmpl.template, 'Hello {{name}}, welcome to {{place}}!');
      expect(tmpl.variables, ['name', 'place']);
    });

    test('fromMap handles missing template key', () {
      final tmpl = PromptTemplate.fromMap(<String, dynamic>{});
      expect(tmpl.template, '');
      expect(tmpl.variables, isEmpty);
    });

    test('fromMap handles missing variables key', () {
      final tmpl = PromptTemplate.fromMap({'template': 'no vars'});
      expect(tmpl.template, 'no vars');
      expect(tmpl.variables, isEmpty);
    });

    test('render substitutes all provided variables', () {
      final tmpl = PromptTemplate(
        template: 'Task: {{task_title}}\nID: {{task_id}}',
        variables: ['task_title', 'task_id'],
      );
      final result = tmpl.render({
        'task_title': 'My Task',
        'task_id': 'abc-123',
      });
      expect(result, 'Task: My Task\nID: abc-123');
    });

    test('render leaves unknown placeholders as-is', () {
      final tmpl = PromptTemplate(
        template: 'Hello {{name}}, your role is {{role}}.',
        variables: ['name', 'role'],
      );
      final result = tmpl.render({'name': 'Alice'});
      expect(result, 'Hello Alice, your role is {{role}}.');
    });

    test('render handles empty values map', () {
      final tmpl = PromptTemplate(
        template: '{{a}} and {{b}}',
        variables: ['a', 'b'],
      );
      final result = tmpl.render({});
      expect(result, '{{a}} and {{b}}');
    });

    test('render handles multiple occurrences of same variable', () {
      final tmpl = PromptTemplate(
        template: '{{x}} plus {{x}} equals two {{x}}',
        variables: ['x'],
      );
      final result = tmpl.render({'x': '1'});
      expect(result, '1 plus 1 equals two 1');
    });
  });

  group('PromptPack', () {
    const validYaml = '''
templates:
  greeting:
    template: |
      Hello {{name}}!
    variables:
      - name
  farewell:
    template: |
      Goodbye {{name}}, see you {{when}}.
    variables:
      - name
      - when
''';

    test('fromYamlString parses valid YAML with multiple templates', () {
      final pack = PromptPack.fromYamlString(validYaml);
      expect(pack.templates.length, 2);
      expect(pack.hasTemplate('greeting'), isTrue);
      expect(pack.hasTemplate('farewell'), isTrue);
    });

    test('fromYamlString returns empty pack for empty string', () {
      // loadYaml on empty string returns null, which is not YamlMap
      final pack = PromptPack.fromYamlString('');
      expect(pack.templates, isEmpty);
    });

    test('fromYamlString returns empty pack for non-map YAML', () {
      final pack = PromptPack.fromYamlString('just a string');
      expect(pack.templates, isEmpty);
    });

    test('fromYamlString returns empty pack for YAML without templates key',
        () {
      final pack = PromptPack.fromYamlString('other_key: value');
      expect(pack.templates, isEmpty);
    });

    test('fromYamlString handles malformed template entries gracefully', () {
      const yaml = '''
templates:
  good:
    template: "hello {{name}}"
    variables:
      - name
  bad_entry: "not a map"
''';
      final pack = PromptPack.fromYamlString(yaml);
      // 'good' should be parsed, 'bad_entry' skipped (not a YamlMap)
      expect(pack.templates.length, 1);
      expect(pack.hasTemplate('good'), isTrue);
      expect(pack.hasTemplate('bad_entry'), isFalse);
    });

    test('getTemplate returns template by name', () {
      final pack = PromptPack.fromYamlString(validYaml);
      final tmpl = pack.getTemplate('greeting');
      expect(tmpl, isNotNull);
      expect(tmpl!.template, contains('Hello {{name}}'));
    });

    test('getTemplate returns null for missing name', () {
      final pack = PromptPack.fromYamlString(validYaml);
      expect(pack.getTemplate('nonexistent'), isNull);
    });

    test('hasTemplate returns correct boolean', () {
      final pack = PromptPack.fromYamlString(validYaml);
      expect(pack.hasTemplate('greeting'), isTrue);
      expect(pack.hasTemplate('nonexistent'), isFalse);
    });

    test('renderTemplate renders correctly', () {
      final pack = PromptPack.fromYamlString(validYaml);
      final result = pack.renderTemplate('farewell', {
        'name': 'Bob',
        'when': 'tomorrow',
      });
      expect(result, contains('Goodbye Bob'));
      expect(result, contains('see you tomorrow'));
    });

    test('renderTemplate throws ArgumentError for unknown template', () {
      final pack = PromptPack.fromYamlString(validYaml);
      expect(
        () => pack.renderTemplate('nonexistent', {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    group('defaults', () {
      test('contains copy_task_prompt and copy_parent_task_prompt', () {
        final pack = PromptPack.defaults();
        expect(pack.hasTemplate('copy_task_prompt'), isTrue);
        expect(pack.hasTemplate('copy_parent_task_prompt'), isTrue);
        expect(pack.templates.length, 2);
      });

      test('copy_task_prompt contains expected placeholders', () {
        final pack = PromptPack.defaults();
        final tmpl = pack.getTemplate('copy_task_prompt')!;
        expect(tmpl.template, contains('{{task_id}}'));
        expect(tmpl.template, contains('{{task_title}}'));
        expect(tmpl.template, contains('{{task_details}}'));
        expect(tmpl.template, contains('{{steps}}'));
        expect(tmpl.variables, containsAll([
          'task_id',
          'task_title',
          'task_details',
          'task_status',
          'project_id',
          'steps',
        ]));
      });

      test('copy_parent_task_prompt contains parent task instructions', () {
        final pack = PromptPack.defaults();
        final tmpl = pack.getTemplate('copy_parent_task_prompt')!;
        expect(tmpl.template, contains('PARENT TASK'));
        expect(tmpl.template, contains('get-subtask-prompt'));
      });

      test('default templates render with all variables', () {
        final pack = PromptPack.defaults();
        final values = {
          'task_id': 'tid-001',
          'task_title': 'Test Task',
          'task_details': 'Some details',
          'task_status': 'started',
          'project_id': 'proj-1',
          'steps': '1. Step one\n2. Step two',
        };
        final result = pack.renderTemplate('copy_task_prompt', values);
        expect(result, contains('tid-001'));
        expect(result, contains('Test Task'));
        expect(result, contains('Some details'));
        expect(result, contains('1. Step one'));
        // No unresolved placeholders
        expect(result, isNot(contains('{{')));
      });
    });
  });
}
