import 'dart:io';
import 'package:test/test.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

void main() {
  group('ServerArguments', () {
    group('parse', () {
      test('single --project-dir argument (= format)', () {
        final args = ServerArguments.parse(['--project-dir=/path/to/project']);

        expect(args.projectDirs, hasLength(1));
        expect(args.projectDirs[0], endsWith('path/to/project'));
        expect(args.plannerDataRoot, isNull);
        expect(args.helpRequested, isFalse);
        expect(args.unknownArguments, isEmpty);
      });

      test('multiple --project-dir arguments', () {
        final args = ServerArguments.parse([
          '--project-dir=/path/to/project1',
          '--project-dir=/path/to/project2',
          '--project-dir=/path/to/project3',
        ]);

        expect(args.projectDirs, hasLength(3));
        expect(args.projectDirs[0], endsWith('path/to/project1'));
        expect(args.projectDirs[1], endsWith('path/to/project2'));
        expect(args.projectDirs[2], endsWith('path/to/project3'));
      });

      test('--project-dir with space separator format', () {
        final args =
            ServerArguments.parse(['--project-dir', '/path/to/project']);

        expect(args.projectDirs, hasLength(1));
        expect(args.projectDirs[0], endsWith('path/to/project'));
      });

      test('--planner-data-root argument (= format)', () {
        final args = ServerArguments.parse(['--planner-data-root=/data/root']);

        expect(args.plannerDataRoot, endsWith('data/root'));
        expect(args.projectDirs, isEmpty);
      });

      test('--planner-data-root with space separator format', () {
        final args =
            ServerArguments.parse(['--planner-data-root', '/data/root']);

        expect(args.plannerDataRoot, endsWith('data/root'));
      });

      test('--prompts-file argument', () {
        final args =
            ServerArguments.parse(['--prompts-file=/path/to/prompts.json']);

        expect(args.promptsFilePath, endsWith('path/to/prompts.json'));
      });

      test('--prompts-file with space separator format', () {
        final args =
            ServerArguments.parse(['--prompts-file', '/path/to/prompts.json']);

        expect(args.promptsFilePath, endsWith('path/to/prompts.json'));
      });

      test('--help flag', () {
        final args = ServerArguments.parse(['--help']);
        expect(args.helpRequested, isTrue);
      });

      test('-h flag', () {
        final args = ServerArguments.parse(['-h']);
        expect(args.helpRequested, isTrue);
      });

      test('combined arguments', () {
        final args = ServerArguments.parse([
          '--project-dir=/project1',
          '--project-dir=/project2',
          '--planner-data-root=/data',
          '--prompts-file=/prompts.json',
        ]);

        expect(args.projectDirs, hasLength(2));
        expect(args.plannerDataRoot, isNotNull);
        expect(args.promptsFilePath, isNotNull);
        expect(args.helpRequested, isFalse);
        expect(args.unknownArguments, isEmpty);
      });

      test('unknown arguments are collected', () {
        final args = ServerArguments.parse([
          '--project-dir=/project',
          '--unknown-flag',
          '--another=value',
        ]);

        expect(args.projectDirs, hasLength(1));
        expect(args.unknownArguments, hasLength(2));
        expect(args.unknownArguments, contains('--unknown-flag'));
        expect(args.unknownArguments, contains('--another=value'));
      });

      test('empty arguments list', () {
        final args = ServerArguments.parse([]);

        expect(args.projectDirs, isEmpty);
        expect(args.plannerDataRoot, isNull);
        expect(args.promptsFilePath, isNull);
        expect(args.helpRequested, isFalse);
        expect(args.unknownArguments, isEmpty);
      });

      test('path normalization - relative paths become absolute', () {
        final args = ServerArguments.parse(['--project-dir=./my-project']);

        expect(args.projectDirs, hasLength(1));
        expect(args.projectDirs[0], isNot(startsWith('.')));
        // Should be an absolute path
        expect(args.projectDirs[0], startsWith('/'));
      });

      test('path normalization - tilde expansion', () {
        final homeDir = Platform.environment['HOME'] ?? '';
        if (homeDir.isNotEmpty) {
          final args = ServerArguments.parse(['--project-dir=~/my-project']);

          expect(args.projectDirs, hasLength(1));
          expect(args.projectDirs[0], startsWith(homeDir));
        }
      });
    });

    group('plannerDbPath', () {
      test('infers correct path', () {
        final args = ServerArguments.parse(
            ['--planner-data-root=/data', '--project-dir=/projects/my-app']);

        final dbPath = args.plannerDbPath('/projects/my-app');
        expect(dbPath, contains('projects/my-app/db/planner.db'));
      });

      test('uses basename of project dir', () {
        final args = ServerArguments.parse([
          '--planner-data-root=/data',
          '--project-dir=/very/long/path/to/my-app'
        ]);

        final dbPath = args.plannerDbPath('/very/long/path/to/my-app');
        expect(dbPath, contains('my-app'));
        expect(dbPath, isNot(contains('very/long')));
      });

      test('throws StateError when plannerDataRoot is null', () {
        final args = ServerArguments.parse(['--project-dir=/projects/my-app']);

        expect(
          () => args.plannerDbPath('/projects/my-app'),
          throwsStateError,
        );
      });

      test('different projects get different paths', () {
        final args = ServerArguments.parse([
          '--planner-data-root=/data',
          '--project-dir=/projects/app1',
          '--project-dir=/projects/app2',
        ]);

        final db1 = args.plannerDbPath('/projects/app1');
        final db2 = args.plannerDbPath('/projects/app2');

        expect(db1, contains('app1'));
        expect(db2, contains('app2'));
        expect(db1, isNot(equals(db2)));
      });
    });

    group('codeIndexDbPath', () {
      test('infers correct path', () {
        final args = ServerArguments.parse(
            ['--planner-data-root=/data', '--project-dir=/projects/my-app']);

        final dbPath = args.codeIndexDbPath('/projects/my-app');
        expect(dbPath, contains('projects/my-app/db/code_index.db'));
      });

      test('throws StateError when plannerDataRoot is null', () {
        final args = ServerArguments.parse(['--project-dir=/projects/my-app']);

        expect(
          () => args.codeIndexDbPath('/projects/my-app'),
          throwsStateError,
        );
      });

      test('different DB filename from planner', () {
        final args = ServerArguments.parse(
            ['--planner-data-root=/data', '--project-dir=/projects/my-app']);

        final plannerDb = args.plannerDbPath('/projects/my-app');
        final codeIndexDb = args.codeIndexDbPath('/projects/my-app');

        expect(plannerDb, contains('planner.db'));
        expect(codeIndexDb, contains('code_index.db'));
        expect(plannerDb, isNot(equals(codeIndexDb)));
      });
    });

    group('toString', () {
      test('produces readable output', () {
        final args = ServerArguments.parse([
          '--project-dir=/project1',
          '--planner-data-root=/data',
        ]);
        final str = args.toString();

        expect(str, contains('ServerArguments'));
        expect(str, contains('projectDirs'));
        expect(str, contains('plannerDataRoot'));
      });
    });
  });
}
