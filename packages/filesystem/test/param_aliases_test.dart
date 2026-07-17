import 'package:filesystem_mcp/filesystem_mcp.dart';
import 'package:test/test.dart';

/// Tests for tolerant line-parameter reading. A misread line parameter is
/// destructive for edit-file (no line params = overwrite entire file), so
/// both spellings must resolve and near-miss spellings must be detected.
void main() {
  group('lineArg', () {
    test('reads canonical spellings', () {
      expect(lineArg({'startLine': 3}, 'startLine'), 3);
      expect(lineArg({'endLine': 7}, 'endLine'), 7);
      expect(lineArg({'insert_at': 5}, 'insert_at'), 5);
    });

    test('reads alias spellings', () {
      expect(lineArg({'start_line': 3}, 'startLine'), 3);
      expect(lineArg({'end_line': 7}, 'endLine'), 7);
      expect(lineArg({'insertAt': 5}, 'insert_at'), 5);
    });

    test('canonical spelling wins when both are present', () {
      expect(lineArg({'startLine': 3, 'start_line': 9}, 'startLine'), 3);
      expect(lineArg({'insert_at': 2, 'insertAt': 8}, 'insert_at'), 2);
    });

    test('returns null when absent and ignores non-numeric values', () {
      expect(lineArg(<String, dynamic>{}, 'startLine'), isNull);
      expect(lineArg({'startLine': 'three'}, 'startLine'), isNull);
      expect(lineArg({'startLine': null}, 'startLine'), isNull);
    });

    test('converts JSON doubles to int', () {
      expect(lineArg({'startLine': 3.0}, 'startLine'), 3);
    });
  });

  group('unrecognizedLineParam', () {
    test('accepts recognized spellings and unrelated keys', () {
      expect(
        unrecognizedLineParam({
          'project_dir': '/x',
          'operation': 'edit-file',
          'path': 'a.txt',
          'content': 'hi',
          'startLine': 1,
          'end_line': 2,
          'insert_at': null,
        }),
        isNull,
      );
    });

    test('flags near-miss spellings that would otherwise be ignored', () {
      expect(unrecognizedLineParam({'start-line': 1}), 'start-line');
      expect(unrecognizedLineParam({'Start_Line': 1}), 'Start_Line');
      expect(unrecognizedLineParam({'end-line': 2}), 'end-line');
      expect(unrecognizedLineParam({'INSERTAT': 3}), 'INSERTAT');
    });

    test('does not flag unrelated keys', () {
      expect(
        unrecognizedLineParam({'destination': 'b.txt', 'pattern': 'line'}),
        isNull,
      );
    });
  });
}
