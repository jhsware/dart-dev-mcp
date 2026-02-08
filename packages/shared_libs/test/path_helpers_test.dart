import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// This replicates the _isAllowedPath function from git_mcp.dart
/// to ensure consistent behavior across implementations
bool gitMcpIsAllowedPath(List<String> allowedPaths, String path) {
  final normalizedPath = p.normalize(path);
  
  return allowedPaths.any((String allowedRoot) {
    final normalizedRoot = p.normalize(allowedRoot);
    
    // Exact match
    if (normalizedPath == normalizedRoot) {
      return true;
    }
    
    // Check if path is a child of the allowed root
    // Ensure we match complete path segments (not partial names)
    // e.g., /lib should match /lib/models but NOT /library
    final rootWithSep = normalizedRoot.endsWith(p.separator) 
        ? normalizedRoot 
        : normalizedRoot + p.separator;
    
    return normalizedPath.startsWith(rootWithSep);
  });
}

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

  group('isAllowedPath (shared implementation)', () {
    group('exact matches', () {
      test('allows exact match of allowed path', () {
        final allowed = ['/home/user/project/lib'];
        expect(isAllowedPath(allowed, '/home/user/project/lib'), isTrue);
      });

      test('allows exact match of allowed file', () {
        final allowed = ['/home/user/project/pubspec.yaml'];
        expect(isAllowedPath(allowed, '/home/user/project/pubspec.yaml'), isTrue);
      });

      test('allows path matching any of multiple allowed paths', () {
        final allowed = ['/project/lib', '/project/bin', '/project/test'];
        expect(isAllowedPath(allowed, '/project/bin'), isTrue);
      });
    });

    group('child paths (subdirectories and nested files)', () {
      test('allows paths within allowed directories', () {
        final allowed = ['/home/user/project/lib', '/home/user/project/bin'];
        expect(
          isAllowedPath(allowed, '/home/user/project/lib/src/file.dart'),
          isTrue,
        );
      });

      test('allows direct child file', () {
        final allowed = ['/project/lib'];
        expect(isAllowedPath(allowed, '/project/lib/main.dart'), isTrue);
      });

      test('allows nested subdirectory', () {
        final allowed = ['/project/lib'];
        expect(isAllowedPath(allowed, '/project/lib/models'), isTrue);
      });

      test('allows file in nested subdirectory', () {
        final allowed = ['/project/lib'];
        expect(isAllowedPath(allowed, '/project/lib/models/user.dart'), isTrue);
      });

      test('allows deeply nested file', () {
        final allowed = ['/project/lib'];
        expect(isAllowedPath(allowed, '/project/lib/src/models/entities/user.dart'), isTrue);
      });

      test('allows file in any of multiple allowed paths', () {
        final allowed = ['/project/lib', '/project/bin', '/project/test'];
        expect(isAllowedPath(allowed, '/project/test/utils/helpers_test.dart'), isTrue);
      });
    });

    group('paths outside allowed paths', () {
      test('rejects paths outside allowed directories', () {
        final allowed = ['/home/user/project/lib', '/home/user/project/bin'];
        expect(isAllowedPath(allowed, '/home/user/other/file.dart'), isFalse);
      });

      test('rejects paths in parent directory', () {
        final allowed = ['/home/user/project/lib'];
        expect(isAllowedPath(allowed, '/home/user/project'), isFalse);
      });

      test('rejects sibling of allowed path', () {
        final allowed = ['/project/lib'];
        expect(isAllowedPath(allowed, '/project/src'), isFalse);
      });

      test('rejects completely unrelated path', () {
        final allowed = ['/project/lib'];
        expect(isAllowedPath(allowed, '/other/lib'), isFalse);
      });
    });

    group('paths with similar prefixes (critical edge cases)', () {
      test('rejects path that starts with similar name but is not a child', () {
        // This is the critical test - /lib should NOT match /library
        final allowed = ['/project/lib'];
        expect(isAllowedPath(allowed, '/project/library/file.dart'), isFalse);
      });

      test('rejects path with allowed path as substring', () {
        final allowed = ['/project/bin'];
        expect(isAllowedPath(allowed, '/project/binary/file.dart'), isFalse);
      });

      test('rejects path with partial directory name match', () {
        final allowed = ['/project/test'];
        expect(isAllowedPath(allowed, '/project/testing/file.dart'), isFalse);
      });

      test('allows actual child despite similar named sibling existing', () {
        final allowed = ['/project/lib'];
        // /project/lib/utils.dart should match even if /project/library exists
        expect(isAllowedPath(allowed, '/project/lib/utils.dart'), isTrue);
      });
    });

    group('path normalization', () {
      test('handles normalized paths with dot segments', () {
        final allowed = ['/home/user/project/lib'];
        expect(
          isAllowedPath(allowed, '/home/user/project/lib/./src/../file.dart'),
          isTrue,
        );
      });

      test('handles paths with double slashes', () {
        final allowed = ['/project/lib'];
        expect(isAllowedPath(allowed, '/project/lib//models/file.dart'), isTrue);
      });
    });

    group('real-world scenarios (the original bug)', () {
      test('allows lib/models/models.dart when ./lib is allowed', () {
        // This was the original failing case
        final allowed = ['/Users/jhsware/DEV/dart_dev_mcp/lib'];
        expect(
          isAllowedPath(allowed, '/Users/jhsware/DEV/dart_dev_mcp/lib/models/models.dart'),
          isTrue,
        );
      });

      test('allows lib/mcp_server/utils/path_helpers.dart when ./lib is allowed', () {
        final allowed = ['/Users/jhsware/DEV/dart_dev_mcp/lib'];
        expect(
          isAllowedPath(allowed, '/Users/jhsware/DEV/dart_dev_mcp/lib/mcp_server/utils/path_helpers.dart'),
          isTrue,
        );
      });

      test('allows test/utils/path_helpers_test.dart when ./test is allowed', () {
        final allowed = ['/Users/jhsware/DEV/dart_dev_mcp/test'];
        expect(
          isAllowedPath(allowed, '/Users/jhsware/DEV/dart_dev_mcp/test/utils/path_helpers_test.dart'),
          isTrue,
        );
      });

      test('rejects lib/models/models.dart when only ./bin is allowed', () {
        final allowed = ['/Users/jhsware/DEV/dart_dev_mcp/bin'];
        expect(
          isAllowedPath(allowed, '/Users/jhsware/DEV/dart_dev_mcp/lib/models/models.dart'),
          isFalse,
        );
      });
    });

    group('create-directory scenarios', () {
      test('allows creating subdirectory lib/models when lib is allowed', () {
        // This is the exact scenario that was failing
        final projectPath = '/Users/jhsware/DEV/dart_dev_mcp';
        final allowed = ['$projectPath/lib'];
        final newDirPath = '$projectPath/lib/models';
        
        expect(isAllowedPath(allowed, newDirPath), isTrue);
      });

      test('allows creating deeply nested directory', () {
        final projectPath = '/Users/dev/project';
        final allowed = ['$projectPath/lib'];
        final newDirPath = '$projectPath/lib/src/models/entities';
        
        expect(isAllowedPath(allowed, newDirPath), isTrue);
      });

      test('rejects creating directory outside allowed path', () {
        final projectPath = '/Users/dev/project';
        final allowed = ['$projectPath/lib'];
        final newDirPath = '$projectPath/src/models';
        
        expect(isAllowedPath(allowed, newDirPath), isFalse);
      });

      test('allows creating directory at exact allowed path', () {
        final projectPath = '/Users/dev/project';
        final allowed = ['$projectPath/lib/models'];
        final newDirPath = '$projectPath/lib/models';
        
        expect(isAllowedPath(allowed, newDirPath), isTrue);
      });
    });
  });

  // Test the git_mcp.dart implementation pattern to ensure it matches
  group('gitMcpIsAllowedPath (git_mcp.dart pattern)', () {
    group('exact matches', () {
      test('allows exact path match', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib'), isTrue);
      });

      test('allows exact file match', () {
        final allowed = ['/project/pubspec.yaml'];
        expect(gitMcpIsAllowedPath(allowed, '/project/pubspec.yaml'), isTrue);
      });
    });

    group('child paths (subdirectories and nested files)', () {
      test('allows direct child file', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib/main.dart'), isTrue);
      });

      test('allows nested subdirectory', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib/models'), isTrue);
      });

      test('allows file in nested subdirectory', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib/models/user.dart'), isTrue);
      });

      test('allows deeply nested file', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib/src/models/entities/user.dart'), isTrue);
      });
    });

    group('paths with similar prefixes (critical edge cases)', () {
      test('rejects path that starts with similar name but is not a child', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/library/file.dart'), isFalse);
      });

      test('rejects path with allowed path as substring', () {
        final allowed = ['/project/bin'];
        expect(gitMcpIsAllowedPath(allowed, '/project/binary/file.dart'), isFalse);
      });

      test('rejects path with partial directory name match', () {
        final allowed = ['/project/test'];
        expect(gitMcpIsAllowedPath(allowed, '/project/testing/file.dart'), isFalse);
      });
    });

    group('paths outside allowed paths', () {
      test('rejects path outside all allowed paths', () {
        final allowed = ['/project/lib', '/project/bin'];
        expect(gitMcpIsAllowedPath(allowed, '/project/src/main.dart'), isFalse);
      });

      test('rejects parent of allowed path', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project'), isFalse);
      });
    });

    group('real-world scenarios (the original bug)', () {
      test('allows lib/models/models.dart when ./lib is allowed', () {
        final allowed = ['/Users/jhsware/DEV/dart_dev_mcp/lib'];
        expect(
          gitMcpIsAllowedPath(allowed, '/Users/jhsware/DEV/dart_dev_mcp/lib/models/models.dart'),
          isTrue,
        );
      });

      test('allows lib/mcp_server/utils/path_helpers.dart when ./lib is allowed', () {
        final allowed = ['/Users/jhsware/DEV/dart_dev_mcp/lib'];
        expect(
          gitMcpIsAllowedPath(allowed, '/Users/jhsware/DEV/dart_dev_mcp/lib/mcp_server/utils/path_helpers.dart'),
          isTrue,
        );
      });
    });
  });

  // Verify both implementations produce identical results
  group('implementation consistency (isAllowedPath vs gitMcpIsAllowedPath)', () {
    final testCases = [
      // [allowedPaths, testPath, expectedResult]
      [['/project/lib'], '/project/lib', true],
      [['/project/lib'], '/project/lib/main.dart', true],
      [['/project/lib'], '/project/lib/models/user.dart', true],
      [['/project/lib'], '/project/lib/src/deep/nested/file.dart', true],
      [['/project/lib'], '/project/library/file.dart', false],
      [['/project/lib'], '/project/src/file.dart', false],
      [['/project/lib'], '/project', false],
      [['/project/lib', '/project/bin'], '/project/bin/main.dart', true],
      [['/project/lib', '/project/bin'], '/project/test/file.dart', false],
    ];

    for (final testCase in testCases) {
      final allowedPaths = testCase[0] as List<String>;
      final testPath = testCase[1] as String;
      final expected = testCase[2] as bool;

      test('both return $expected for "$testPath" with allowed=$allowedPaths', () {
        expect(isAllowedPath(allowedPaths, testPath), equals(expected),
            reason: 'isAllowedPath failed');
        expect(gitMcpIsAllowedPath(allowedPaths, testPath), equals(expected),
            reason: 'gitMcpIsAllowedPath failed');
      });
    }
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
