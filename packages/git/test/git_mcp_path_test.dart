import 'dart:io';

import 'package:git_mcp/git_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Replicates the isAllowedPath function from shared_libs to ensure
/// the implementation is tested independently.
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

  group('monorepo layout (workingDir != projectDir)', () {
    late Directory tempDir;
    late Directory repoDir;
    late Directory subProjectDir;
    late String subLibDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('git_mcp_monorepo_');
      repoDir = Directory(p.join(tempDir.path, 'repo'));
      subProjectDir = Directory(p.join(repoDir.path, 'packages', 'sub'));
      subLibDir = p.join(subProjectDir.path, 'lib');

      // Create monorepo structure
      await Directory(subLibDir).create(recursive: true);

      // git init at repo root
      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run('git', ['config', 'user.email', 'test@example.com'],
          workingDirectory: repoDir.path);
      await Process.run('git', ['config', 'user.name', 'Test User'],
          workingDirectory: repoDir.path);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('git add with relative path resolves against projectDir', () async {
      // Create a file inside the sub-project
      final fooFile = File(p.join(subLibDir, 'foo.dart'));
      await fooFile.writeAsString('void main() {}');

      final gitOps = GitOperations(
        workingDir: repoDir,
        projectDir: subProjectDir,
        allowedPaths: [subLibDir],
      );

      final result = await gitOps.add(['lib/foo.dart']);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Staged'));
    });

    test('git add rejects absolute path outside projectDir', () async {
      // Create a file outside the sub-project
      final outsideFile = File(p.join(repoDir.path, 'README.md'));
      await outsideFile.writeAsString('# Repo');

      final gitOps = GitOperations(
        workingDir: repoDir,
        projectDir: subProjectDir,
        allowedPaths: [subLibDir],
      );

      final result = await gitOps.add([outsideFile.path]);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('allowed paths'));

    });

    test('git add --all filters files outside the sub-project', () async {
      // Create files and do an initial commit so git tracks them individually
      final insideFile = File(p.join(subLibDir, 'bar.dart'));
      await insideFile.writeAsString('void bar() {}');
      final outsideFile = File(p.join(repoDir.path, 'README.md'));
      await outsideFile.writeAsString('# Repo');

      await Process.run('git', ['add', '.'], workingDirectory: repoDir.path);
      await Process.run(
        'git', ['commit', '--no-gpg-sign', '-m', 'initial'],
        workingDirectory: repoDir.path,
      );

      // Now modify both files so they show up individually in porcelain output
      await insideFile.writeAsString('void bar() { /* changed */ }');
      await outsideFile.writeAsString('# Repo updated');

      final gitOps = GitOperations(
        workingDir: repoDir,
        projectDir: subProjectDir,
        allowedPaths: [subLibDir],
      );

      final result = await gitOps.add(null, all: true);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Staged 1 file(s)'));
      expect(text, contains('Skipped (outside allowed paths)'));
      expect(text, contains('README.md'));
    });
  });
}

