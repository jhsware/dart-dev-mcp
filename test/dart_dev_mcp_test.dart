import 'dart:io';

import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('Line Endings', () {
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
  });

  group('Path Helpers', () {
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
  });

  group('Session Manager', () {
    late SessionManager sessionManager;

    setUp(() {
      // Create a fresh instance for testing
      // Note: SessionManager is a singleton, so we need to work around this
      sessionManager = SessionManager();
    });

    group('ProcessSession', () {
      test('creates session with correct properties', () {
        final session = ProcessSession(
          id: 'test_session',
          operation: 'test',
          description: 'Test operation',
        );

        expect(session.id, 'test_session');
        expect(session.operation, 'test');
        expect(session.description, 'Test operation');
        expect(session.isComplete, isFalse);
        expect(session.chunks, isEmpty);
        expect(session.startedAt, isNotNull);
      });

      test('collects output from stream', () async {
        final session = ProcessSession(
          id: 'test_session',
          operation: 'test',
          description: 'Test operation',
        );

        final stream = Stream.fromIterable(['chunk1', 'chunk2', 'chunk3']);
        session.collectOutput(stream);

        // Wait for stream to complete
        await Future.delayed(Duration(milliseconds: 100));

        expect(session.chunks, ['chunk1', 'chunk2', 'chunk3']);
        expect(session.isComplete, isTrue);
      });

      test('cancel stops collection', () async {
        final session = ProcessSession(
          id: 'test_session',
          operation: 'test',
          description: 'Test operation',
        );

        await session.cancel();
        expect(session.isComplete, isTrue);
      });
    });

    group('SessionManager', () {
      test('creates session with unique ID', () {
        final id1 = sessionManager.createSession('op1', 'desc1');
        final id2 = sessionManager.createSession('op2', 'desc2');

        expect(id1, isNot(equals(id2)));
        expect(id1, startsWith('session_'));
        expect(id2, startsWith('session_'));
      });

      test('retrieves session by ID', () {
        final id = sessionManager.createSession('test', 'Test session');
        final session = sessionManager.getSession(id);

        expect(session, isNotNull);
        expect(session!.operation, 'test');
        expect(session.description, 'Test session');
      });

      test('returns null for unknown session ID', () {
        final session = sessionManager.getSession('unknown_id');
        expect(session, isNull);
      });

      test('removes session', () async {
        final id = sessionManager.createSession('test', 'Test session');
        expect(sessionManager.getSession(id), isNotNull);

        await sessionManager.removeSession(id);
        expect(sessionManager.getSession(id), isNull);
      });

      test('lists all sessions', () {
        sessionManager.createSession('op1', 'desc1');
        sessionManager.createSession('op2', 'desc2');

        final all = sessionManager.allSessions;
        expect(all.length, greaterThanOrEqualTo(2));
      });

      test('lists only active sessions', () {
        final id = sessionManager.createSession('test', 'Test session');
        final session = sessionManager.getSession(id)!;

        // Session should be active initially
        expect(
          sessionManager.activeSessions.any((s) => s.id == id),
          isTrue,
        );

        // Mark as complete
        session.isComplete = true;

        // Session should no longer be active
        expect(
          sessionManager.activeSessions.any((s) => s.id == id),
          isFalse,
        );
      });
    });

    group('runCommand', () {
      test('runs echo command successfully', () async {
        final result = await runCommand(
          Directory.current,
          'echo',
          ['hello'],
        );

        expect(result.exitCode, 0);
        expect((result.stdout as String).trim(), 'hello');
      });

      test('returns non-zero exit code for failing command', () async {
        final result = await runCommand(
          Directory.current,
          'ls',
          ['/nonexistent/path/that/does/not/exist'],
        );

        expect(result.exitCode, isNot(0));
      });
    });

    group('streamCommand', () {
      test('streams command output', () async {
        final chunks = <String>[];

        await for (final chunk in streamCommand(
          Directory.current,
          'echo',
          ['hello', 'world'],
        )) {
          chunks.add(chunk);
        }

        final output = chunks.join();
        expect(output, contains('hello'));
        expect(output, contains('world'));
      });

      test('reports completion', () async {
        final chunks = <String>[];

        await for (final chunk in streamCommand(
          Directory.current,
          'echo',
          ['test'],
        )) {
          chunks.add(chunk);
        }

        final output = chunks.join();
        expect(output, contains('completed successfully'));
      });
    });
  });
}
