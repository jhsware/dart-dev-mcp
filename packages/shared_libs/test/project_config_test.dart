import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('project_config_test_');
    ProjectConfigService.clearCache();
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
    ProjectConfigService.clearCache();
  });

  group('ProjectConfig', () {
    test('empty config has no toolPaths and hasConfig is false', () {
      expect(ProjectConfig.empty.toolPaths, isEmpty);
      expect(ProjectConfig.empty.hasConfig, isFalse);
    });

    test('non-empty config has hasConfig true', () {
      final config = ProjectConfig({
        'filesystem': ['./lib'],
      });
      expect(config.hasConfig, isTrue);
    });
  });

  group('ProjectConfigService.loadConfig', () {
    test('returns empty config when file does not exist', () {
      final config = ProjectConfigService.loadConfig(tempDir.path);
      expect(config.hasConfig, isFalse);
      expect(config.toolPaths, isEmpty);
    });

    test('parses valid config with multiple tool entries', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('''
filesystem:
  - ./pubspec.yaml
  - ./lib
  - ./test
git:
  - ./pubspec.yaml
  - ./lib
  - ./test
  - ./bin
''');

      final config = ProjectConfigService.loadConfig(tempDir.path);
      expect(config.hasConfig, isTrue);
      expect(config.toolPaths.keys, containsAll(['filesystem', 'git']));
      expect(config.toolPaths['filesystem'], ['./pubspec.yaml', './lib', './test']);
      expect(config.toolPaths['git'], ['./pubspec.yaml', './lib', './test', './bin']);
    });

    test('handles tool with null value as empty list', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('''
filesystem:
  - ./lib
dart_runner:
''');

      final config = ProjectConfigService.loadConfig(tempDir.path);
      expect(config.toolPaths['filesystem'], ['./lib']);
      expect(config.toolPaths['dart_runner'], isEmpty);
    });

    test('throws FormatException for malformed YAML', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('{{{{invalid yaml');

      expect(
        () => ProjectConfigService.loadConfig(tempDir.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when top level is not a map', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('- item1\n- item2');

      expect(
        () => ProjectConfigService.loadConfig(tempDir.path),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('expected a YAML map'),
        )),
      );
    });

    test('throws FormatException when value is not a list', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('filesystem: not_a_list');

      expect(
        () => ProjectConfigService.loadConfig(tempDir.path),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('expected a list'),
        )),
      );
    });

    test('throws FormatException when list item is not a string', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('filesystem:\n  - 123');

      expect(
        () => ProjectConfigService.loadConfig(tempDir.path),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('expected string path'),
        )),
      );
    });

    test('returns empty config for empty YAML file', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('');

      final config = ProjectConfigService.loadConfig(tempDir.path);
      expect(config.hasConfig, isFalse);
    });

    test('caches config and returns same result on second call', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('filesystem:\n  - ./lib');

      final config1 = ProjectConfigService.loadConfig(tempDir.path);
      final config2 = ProjectConfigService.loadConfig(tempDir.path);

      // Same object from cache
      expect(identical(config1, config2), isTrue);
    });

    test('cache is invalidated when file modification time changes', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('filesystem:\n  - ./lib');

      final config1 = ProjectConfigService.loadConfig(tempDir.path);
      expect(config1.toolPaths['filesystem'], ['./lib']);

      // Filesystem mod time has ~1s granularity, wait to ensure it changes
      sleep(Duration(seconds: 1, milliseconds: 100));
      configFile.writeAsStringSync('filesystem:\n  - ./lib\n  - ./test');

      final config2 = ProjectConfigService.loadConfig(tempDir.path);
      expect(config2.toolPaths['filesystem'], ['./lib', './test']);
      expect(identical(config1, config2), isFalse);
    });

    test('clearCache forces re-read on next call', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('filesystem:\n  - ./lib');

      final config1 = ProjectConfigService.loadConfig(tempDir.path);
      expect(config1.toolPaths['filesystem'], ['./lib']);

      ProjectConfigService.clearCache();
      configFile.writeAsStringSync('filesystem:\n  - ./src');

      final config2 = ProjectConfigService.loadConfig(tempDir.path);
      expect(config2.toolPaths['filesystem'], ['./src']);
    });
  });


  group('ProjectConfigService.getAllowedPaths', () {
    test('returns full project root when no config file exists', () {
      final paths = ProjectConfigService.getAllowedPaths(tempDir.path, 'filesystem');
      expect(paths, hasLength(1));
      expect(paths.first, p.normalize(p.absolute(tempDir.path)));
    });

    test('returns full project root when tool not in config', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('filesystem:\n  - ./lib');

      final paths = ProjectConfigService.getAllowedPaths(tempDir.path, 'unknown_tool');
      expect(paths, hasLength(1));
      expect(paths.first, p.normalize(p.absolute(tempDir.path)));
    });

    test('returns empty list when tool has empty entry', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('filesystem:\n  - ./lib\ndart_runner:');

      final paths = ProjectConfigService.getAllowedPaths(tempDir.path, 'dart_runner');
      expect(paths, isEmpty);
    });

    test('resolves relative paths to absolute paths', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('filesystem:\n  - ./lib\n  - ./test');

      final paths = ProjectConfigService.getAllowedPaths(tempDir.path, 'filesystem');
      final absRoot = p.normalize(p.absolute(tempDir.path));

      expect(paths, hasLength(2));
      expect(paths[0], p.normalize(p.join(absRoot, 'lib')));
      expect(paths[1], p.normalize(p.join(absRoot, 'test')));
    });

    test('resolves paths with file names correctly', () {
      final configFile = File(p.join(tempDir.path, configFileName));
      configFile.writeAsStringSync('git:\n  - ./pubspec.yaml\n  - ./lib');

      final paths = ProjectConfigService.getAllowedPaths(tempDir.path, 'git');
      final absRoot = p.normalize(p.absolute(tempDir.path));

      expect(paths, hasLength(2));
      expect(paths[0], p.normalize(p.join(absRoot, 'pubspec.yaml')));
      expect(paths[1], p.normalize(p.join(absRoot, 'lib')));
    });
  });
}
