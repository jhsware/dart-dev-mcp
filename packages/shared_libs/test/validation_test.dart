import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

String resultText(CallToolResult result) =>
    (result.content.first as TextContent).text;

void main() {
  group('checkUnknownArgs', () {
    const allowed = {'project_dir', 'operation', 'path', 'content'};

    test('passes when every key is recognized', () {
      expect(
        checkUnknownArgs(
          {'project_dir': '/x', 'operation': 'edit-file', 'path': 'a'},
          'edit-file',
          allowed,
        ),
        isNull,
      );
    });

    test('rejects an unknown key and lists recognized arguments', () {
      final result = checkUnknownArgs(
        {'project_dir': '/x', 'operation': 'edit-file', 'start_lin': 3},
        'edit-file',
        allowed,
      );
      expect(result, isNotNull);
      final text = resultText(result!);
      expect(text, contains('start_lin'));
      expect(text, contains('Recognized arguments'));
      expect(text, contains('content'));
    });

    test('reports every unknown key', () {
      final result = checkUnknownArgs(
        {'project_dir': '/x', 'bogus_a': 1, 'bogus_b': 2},
        'status',
        allowed,
      );
      final text = resultText(result!);
      expect(text, contains('bogus_a'));
      expect(text, contains('bogus_b'));
    });

    test('skips keys carrying null (absent-equivalent)', () {
      expect(
        checkUnknownArgs(
          {'project_dir': '/x', 'unknown_key': null},
          'status',
          allowed,
        ),
        isNull,
      );
    });
  });
}
