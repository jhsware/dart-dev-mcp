import 'dart:io';

import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('getAbsolutePath', () {
    test('resolves relative path from working directory', () {
      final workingDir = Directory('/home/user/project');
      expect(
        getAbsolutePath(workingDir, 'lib/src/file.dart'),
        '/home/user/project/lib/src/file.dart',
      );
    });

    test('handles dot (current directory)', () {
      final workingDir = Directory('/home/user/project');
      final result = getAbsolutePath(workingDir, '.');
      // The result should be the normalized absolute path
      expect(result, contains('project'));
    });

    test('normalizes paths with redundant separators', () {
      final workingDir = Directory('/home/user/project');
      final result = getAbsolutePath(workingDir, 'lib//src');
      expect(result, isNot(contains('//')));
    });
  });

  group('isHiddenPath', () {
    test('detects hidden file at root', () {
      expect(isHiddenPath('.hidden'), isTrue);
    });

    test('detects hidden directory in path', () {
      expect(isHiddenPath('lib/.hidden/file.dart'), isTrue);
    });

    test('detects hidden file in subdirectory', () {
      expect(isHiddenPath('lib/src/.gitignore'), isTrue);
    });

    test('accepts normal paths', () {
      expect(isHiddenPath('lib/src/file.dart'), isFalse);
    });

    test('accepts paths with dots in filenames', () {
      expect(isHiddenPath('lib/file.test.dart'), isFalse);
    });
  });

  group('isAllowedPath', () {
    test('allows paths within allowed directories', () {
      final allowed = ['/home/user/project/lib', '/home/user/project/bin'];
      expect(
        isAllowedPath(allowed, '/home/user/project/lib/src/file.dart'),
        isTrue,
      );
    });

    test('allows exact match of allowed path', () {
      final allowed = ['/home/user/project/lib'];
      expect(isAllowedPath(allowed, '/home/user/project/lib'), isTrue);
    });

    test('rejects paths outside allowed directories', () {
      final allowed = ['/home/user/project/lib', '/home/user/project/bin'];
      expect(isAllowedPath(allowed, '/home/user/other/file.dart'), isFalse);
    });

    test('rejects paths in parent directory', () {
      final allowed = ['/home/user/project/lib'];
      expect(isAllowedPath(allowed, '/home/user/project'), isFalse);
    });

    test('handles normalized paths', () {
      final allowed = ['/home/user/project/lib'];
      expect(
        isAllowedPath(allowed, '/home/user/project/lib/./src/../file.dart'),
        isTrue,
      );
    });
  });

  group('validateRelativePath', () {
    test('rejects absolute paths', () {
      expect(validateRelativePath('/etc/passwd'), 'No absolute paths allowed');
    });

    test('rejects hidden files', () {
      expect(
        validateRelativePath('.hidden/file'),
        'No hidden files or directories allowed',
      );
    });

    test('rejects hidden directories in path', () {
      expect(
        validateRelativePath('lib/.git/config'),
        'No hidden files or directories allowed',
      );
    });

    test('rejects parent traversal', () {
      expect(validateRelativePath('../etc/passwd'), isNotNull);
    });

    test('rejects parent traversal in middle of path', () {
      expect(validateRelativePath('lib/../../../etc/passwd'), isNotNull);
    });

    test('accepts valid paths', () {
      expect(validateRelativePath('lib/src/file.dart'), isNull);
    });

    test('accepts simple filename', () {
      expect(validateRelativePath('file.dart'), isNull);
    });

    test('accepts nested paths', () {
      expect(validateRelativePath('a/b/c/d/e/file.dart'), isNull);
    });
  });
}
