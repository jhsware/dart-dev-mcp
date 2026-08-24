import 'package:jhsware_code_filesystem/filesystem_mcp.dart';
import 'package:test/test.dart';

/// Tests for tolerant line-parameter reading. A misread line parameter is
/// destructive for edit-file, so both spellings must resolve to the same
/// value. Unrecognized spellings are rejected by the dispatcher's
/// per-operation unknown-argument check (see shared_libs checkUnknownArgs).
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
}
