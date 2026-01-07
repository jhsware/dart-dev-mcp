import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeLineEndings', () {
    test('converts CRLF to LF', () {
      expect(normalizeLineEndings('hello\r\nworld'), 'hello\nworld');
    });

    test('keeps LF as is', () {
      expect(normalizeLineEndings('hello\nworld'), 'hello\nworld');
    });

    test('converts standalone CR to LF', () {
      expect(normalizeLineEndings('hello\rworld'), 'hello\nworld');
    });

    test('handles mixed line endings', () {
      expect(
        normalizeLineEndings('a\r\nb\nc\rd'),
        'a\nb\nc\nd',
      );
    });

    test('handles empty string', () {
      expect(normalizeLineEndings(''), '');
    });

    test('handles string with no line endings', () {
      expect(normalizeLineEndings('hello world'), 'hello world');
    });
  });

  group('detectLineEndings', () {
    test('detects Unix style (LF)', () {
      expect(detectLineEndings('hello\nworld'), LineEndingStyle.unix);
    });

    test('detects Windows style (CRLF)', () {
      expect(detectLineEndings('hello\r\nworld'), LineEndingStyle.windows);
    });

    test('detects mixed style', () {
      expect(detectLineEndings('a\r\nb\nc'), LineEndingStyle.mixed);
    });

    test('returns unix for empty string', () {
      expect(detectLineEndings(''), LineEndingStyle.unix);
    });

    test('returns unix for string with no line endings', () {
      expect(detectLineEndings('hello world'), LineEndingStyle.unix);
    });

    test('detects multiple CRLF as windows', () {
      expect(
        detectLineEndings('a\r\nb\r\nc\r\n'),
        LineEndingStyle.windows,
      );
    });
  });

  group('applyLineEndings', () {
    test('applies Windows style (CRLF)', () {
      expect(
        applyLineEndings('hello\nworld', LineEndingStyle.windows),
        'hello\r\nworld',
      );
    });

    test('keeps Unix style unchanged', () {
      expect(
        applyLineEndings('hello\nworld', LineEndingStyle.unix),
        'hello\nworld',
      );
    });

    test('treats mixed as Unix style', () {
      expect(
        applyLineEndings('hello\nworld', LineEndingStyle.mixed),
        'hello\nworld',
      );
    });

    test('handles empty string', () {
      expect(applyLineEndings('', LineEndingStyle.windows), '');
    });

    test('handles multiple line endings', () {
      expect(
        applyLineEndings('a\nb\nc', LineEndingStyle.windows),
        'a\r\nb\r\nc',
      );
    });
  });

  group('addLineNumbers', () {
    test('adds correct prefixes', () {
      expect(addLineNumbers('a\nb\nc'), 'L1: a\nL2: b\nL3: c');
    });

    test('handles single line', () {
      expect(addLineNumbers('hello'), 'L1: hello');
    });

    test('handles empty string', () {
      expect(addLineNumbers(''), '');
    });

    test('handles empty lines', () {
      expect(addLineNumbers('a\n\nc'), 'L1: a\nL2: \nL3: c');
    });

    test('handles trailing newline', () {
      expect(addLineNumbers('a\nb\n'), 'L1: a\nL2: b\nL3: ');
    });
  });

  group('stripLineNumbers', () {
    test('removes prefixes', () {
      expect(stripLineNumbers('L1: a\nL2: b\nL3: c'), 'a\nb\nc');
    });

    test('handles single line', () {
      expect(stripLineNumbers('L1: hello'), 'hello');
    });

    test('handles empty string', () {
      expect(stripLineNumbers(''), '');
    });

    test('keeps lines without prefixes unchanged', () {
      expect(stripLineNumbers('no prefix here'), 'no prefix here');
    });

    test('handles mixed lines with and without prefixes', () {
      expect(
        stripLineNumbers('L1: a\nno prefix\nL3: c'),
        'a\nno prefix\nc',
      );
    });

    test('handles high line numbers', () {
      expect(stripLineNumbers('L999: content'), 'content');
    });

    test('preserves content with colons', () {
      expect(stripLineNumbers('L1: key: value'), 'key: value');
    });
  });
}
