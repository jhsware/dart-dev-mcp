import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('Line Endings', () {
    test('normalizeLineEndings converts CRLF to LF', () {
      expect(normalizeLineEndings('hello\r\nworld'), 'hello\nworld');
    });

    test('normalizeLineEndings keeps LF as is', () {
      expect(normalizeLineEndings('hello\nworld'), 'hello\nworld');
    });

    test('detectLineEndings detects Unix style', () {
      expect(detectLineEndings('hello\nworld'), LineEndingStyle.unix);
    });

    test('detectLineEndings detects Windows style', () {
      expect(detectLineEndings('hello\r\nworld'), LineEndingStyle.windows);
    });

    test('addLineNumbers adds correct prefixes', () {
      expect(addLineNumbers('a\nb\nc'), 'L1: a\nL2: b\nL3: c');
    });

    test('stripLineNumbers removes prefixes', () {
      expect(stripLineNumbers('L1: a\nL2: b\nL3: c'), 'a\nb\nc');
    });
  });

  group('Path Helpers', () {
    test('validateRelativePath rejects absolute paths', () {
      expect(validateRelativePath('/etc/passwd'), 'No absolute paths allowed');
    });

    test('validateRelativePath rejects hidden files', () {
      expect(validateRelativePath('.hidden/file'), 'No hidden files or directories allowed');
    });

    test('validateRelativePath rejects parent traversal', () {
      expect(validateRelativePath('../etc/passwd'), isNotNull);
    });

    test('validateRelativePath accepts valid paths', () {
      expect(validateRelativePath('lib/src/file.dart'), isNull);
    });

    test('isAllowedPath checks path prefixes', () {
      final allowed = ['/home/user/project/lib', '/home/user/project/bin'];
      expect(isAllowedPath(allowed, '/home/user/project/lib/src/file.dart'), isTrue);
      expect(isAllowedPath(allowed, '/home/user/other/file.dart'), isFalse);
    });
  });
}
