import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// This replicates the exact _isAllowedPath function from bin/git_mcp.dart
/// to ensure the implementation is tested.
/// 
/// IMPORTANT: If you change _isAllowedPath in git_mcp.dart, update this copy too!
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
  group('git_mcp _isAllowedPath', () {
    group('exact matches', () {
      test('allows exact path match', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib'), isTrue);
      });

      test('allows exact file match', () {
        final allowed = ['/project/pubspec.yaml'];
        expect(gitMcpIsAllowedPath(allowed, '/project/pubspec.yaml'), isTrue);
      });

      test('allows path matching any of multiple allowed paths', () {
        final allowed = ['/project/lib', '/project/bin', '/project/test'];
        expect(gitMcpIsAllowedPath(allowed, '/project/bin'), isTrue);
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

      test('allows file in any of multiple allowed paths', () {
        final allowed = ['/project/lib', '/project/bin', '/project/test'];
        expect(gitMcpIsAllowedPath(allowed, '/project/test/utils/helpers_test.dart'), isTrue);
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

      test('rejects sibling of allowed path', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/src'), isFalse);
      });

      test('rejects completely unrelated path', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/other/lib'), isFalse);
      });
    });

    group('paths with similar prefixes (critical edge cases)', () {
      test('rejects path that starts with similar name but is not a child', () {
        // This is the critical test - /lib should NOT match /library
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

      test('allows actual child despite similar named sibling existing', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib/utils.dart'), isTrue);
      });
    });

    group('path normalization', () {
      test('handles paths with double slashes', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib//models/file.dart'), isTrue);
      });

      test('handles paths with dot segments', () {
        final allowed = ['/project/lib'];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib/./models/../file.dart'), isTrue);
      });
    });

    group('real-world scenarios (the original bug)', () {
      test('allows lib/models/models.dart when ./lib is allowed', () {
        // This was the original failing case
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

      test('allows test/utils/path_helpers_test.dart when ./test is allowed', () {
        final allowed = ['/Users/jhsware/DEV/dart_dev_mcp/test'];
        expect(
          gitMcpIsAllowedPath(allowed, '/Users/jhsware/DEV/dart_dev_mcp/test/utils/path_helpers_test.dart'),
          isTrue,
        );
      });

      test('rejects lib/models/models.dart when only ./bin is allowed', () {
        final allowed = ['/Users/jhsware/DEV/dart_dev_mcp/bin'];
        expect(
          gitMcpIsAllowedPath(allowed, '/Users/jhsware/DEV/dart_dev_mcp/lib/models/models.dart'),
          isFalse,
        );
      });
    });

    group('git staging scenarios', () {
      test('allows staging file in lib when lib is allowed', () {
        final projectPath = '/Users/dev/myproject';
        final allowed = ['$projectPath/lib', '$projectPath/bin'];
        
        // Simulates: git add lib/src/feature.dart
        final filePath = '$projectPath/lib/src/feature.dart';
        expect(gitMcpIsAllowedPath(allowed, filePath), isTrue);
      });

      test('rejects staging file outside allowed paths', () {
        final projectPath = '/Users/dev/myproject';
        final allowed = ['$projectPath/lib', '$projectPath/bin'];
        
        // Simulates: git add .env (should be rejected)
        final filePath = '$projectPath/.env';
        expect(gitMcpIsAllowedPath(allowed, filePath), isFalse);
      });

      test('rejects staging file in docs when only lib/bin allowed', () {
        final projectPath = '/Users/dev/myproject';
        final allowed = ['$projectPath/lib', '$projectPath/bin'];
        
        // Simulates: git add docs/README.md
        final filePath = '$projectPath/docs/README.md';
        expect(gitMcpIsAllowedPath(allowed, filePath), isFalse);
      });

      test('allows staging pubspec.yaml when explicitly allowed', () {
        final projectPath = '/Users/dev/myproject';
        final allowed = ['$projectPath/lib', '$projectPath/pubspec.yaml'];
        
        final filePath = '$projectPath/pubspec.yaml';
        expect(gitMcpIsAllowedPath(allowed, filePath), isTrue);
      });
    });

    group('edge cases', () {
      test('handles empty allowed paths list', () {
        final allowed = <String>[];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib/file.dart'), isFalse);
      });

      test('handles root path as allowed', () {
        final allowed = ['/'];
        expect(gitMcpIsAllowedPath(allowed, '/project/lib/file.dart'), isTrue);
      });

      test('handles single file as allowed path', () {
        final allowed = ['/project/README.md'];
        expect(gitMcpIsAllowedPath(allowed, '/project/README.md'), isTrue);
        expect(gitMcpIsAllowedPath(allowed, '/project/README.md.bak'), isFalse);
      });
    });
  });
}
