import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:test/test.dart';

void main() {
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
}
