@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:convert';

import 'package:apple_mail_mcp/apple_mail_mcp.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// Diagnostic test suite to isolate mdfind behavior and identify why
/// Spotlight-based email search returns 0 results.
///
/// Each test prints detailed diagnostic output. Run with:
///   dart test packages/apple_mail_mcp/test/integration/mdfind_diagnostic_test.dart -t integration --reporter expanded
void main() {
  late String homeDir;

  setUpAll(() {
    homeDir = Platform.environment['HOME'] ?? '/tmp';
    // ignore: avoid_print
    print('\n════════════════════════════════════════════════════');
    // ignore: avoid_print
    print('  MDFIND DIAGNOSTIC TESTS');
    // ignore: avoid_print
    print('  Home: $homeDir');
    // ignore: avoid_print
    print('════════════════════════════════════════════════════\n');
  });

  group('Diagnostic', () {
    test('1. Check FDA status', () async {
      final fdaStatus = await checkFullDiskAccess();
      // ignore: avoid_print
      print('FDA status: $fdaStatus');
      // ignore: avoid_print
      print('  true = FDA granted');
      // ignore: avoid_print
      print('  false = FDA denied');
      // ignore: avoid_print
      print('  null = ~/Library/Mail does not exist');

      if (fdaStatus == false) {
        // ignore: avoid_print
        print('RESULT: FAIL — FDA not granted, mdfind will return 0 results');
      } else if (fdaStatus == true) {
        // ignore: avoid_print
        print('RESULT: PASS — FDA granted');
      } else {
        // ignore: avoid_print
        print('RESULT: SKIP — no Mail directory');
      }
    });

    test('2. Find .emlx files via filesystem', () async {
      final mailDir = Directory('$homeDir/Library/Mail');
      if (!await mailDir.exists()) {
        // ignore: avoid_print
        print('RESULT: SKIP — ~/Library/Mail does not exist');
        return;
      }

      // Try to find .emlx files by walking the directory tree
      var emlxCount = 0;
      String? firstEmlxPath;

      try {
        await for (final entity
            in mailDir.list(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.endsWith('.emlx')) {
            emlxCount++;
            firstEmlxPath ??= entity.path;
            if (emlxCount >= 10) break; // Don't scan everything
          }
        }
      } catch (e) {
        // ignore: avoid_print
        print('Error listing directory: $e');
      }

      // ignore: avoid_print
      print('Found $emlxCount+ .emlx files via filesystem');
      if (firstEmlxPath != null) {
        // ignore: avoid_print
        print('First .emlx: $firstEmlxPath');
      }
      // ignore: avoid_print
      print(
          'RESULT: ${emlxCount > 0 ? "PASS" : "FAIL"} — .emlx files ${emlxCount > 0 ? "exist" : "NOT found"}');
    });

    test('3. Run mdls on a known .emlx file', () async {
      final mailDir = Directory('$homeDir/Library/Mail');
      if (!await mailDir.exists()) {
        // ignore: avoid_print
        print('RESULT: SKIP — ~/Library/Mail does not exist');
        return;
      }

      // Find a .emlx file
      String? emlxPath;
      try {
        await for (final entity
            in mailDir.list(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.endsWith('.emlx')) {
            emlxPath = entity.path;
            break;
          }
        }
      } catch (e) {
        // ignore: avoid_print
        print('Error finding .emlx: $e');
      }

      if (emlxPath == null) {
        // ignore: avoid_print
        print('RESULT: SKIP — no .emlx file found');
        return;
      }

      // Run mdls on it
      // ignore: avoid_print
      print('Running mdls on: $emlxPath');
      try {
        final mdlsResult = await runMdls(emlxPath, attributes: [
          'kMDItemContentType',
          'kMDItemContentTypeTree',
          'kMDItemKind',
          'kMDItemTitle',
          'kMDItemAuthors',
          'kMDItemContentCreationDate',
        ]);

        for (final entry in mdlsResult.entries) {
          // ignore: avoid_print
          print('  ${entry.key} = ${entry.value}');
        }

        final contentType = mdlsResult['kMDItemContentType'];
        // ignore: avoid_print
        print(
            '\nActual content type: "$contentType" (expected: "com.apple.mail.emlx")');
        // ignore: avoid_print
        print(
            'RESULT: ${contentType == "com.apple.mail.emlx" ? "PASS" : "FAIL"} — content type ${contentType == "com.apple.mail.emlx" ? "matches" : "MISMATCH: got $contentType"}');
      } catch (e) {
        // ignore: avoid_print
        print('mdls error: $e');
        // ignore: avoid_print
        print('RESULT: FAIL — mdls failed');
      }
    });

    test('4. Raw mdfind without directory scoping', () async {
      // Simplest possible mdfind query — no directory scoping
      // ignore: avoid_print
      print('Running: mdfind \'kMDItemContentType == "com.apple.mail.emlx"\'');

      try {
        final result = await Process.run('mdfind', [
          'kMDItemContentType == "com.apple.mail.emlx"',
        ]);

        final stdout = (result.stdout as String).trim();
        final stderr = (result.stderr as String).trim();
        final lines =
            stdout.split('\n').where((l) => l.trim().isNotEmpty).toList();

        // ignore: avoid_print
        print('Exit code: ${result.exitCode}');
        // ignore: avoid_print
        print('Result count: ${lines.length}');
        if (lines.isNotEmpty) {
          // ignore: avoid_print
          print('First 3 results:');
          for (final line in lines.take(3)) {
            // ignore: avoid_print
            print('  $line');
          }
        }
        if (stderr.isNotEmpty) {
          // ignore: avoid_print
          print('Stderr: $stderr');
        }

        // ignore: avoid_print
        print(
            'RESULT: ${lines.isNotEmpty ? "PASS" : "FAIL"} — mdfind (no scope) returned ${lines.length} results');
      } catch (e) {
        // ignore: avoid_print
        print('mdfind error: $e');
        // ignore: avoid_print
        print('RESULT: FAIL — mdfind threw exception');
      }
    });

    test('5. Raw mdfind WITH directory scoping', () async {
      final expandedPath = '$homeDir/Library/Mail';
      // ignore: avoid_print
      print(
          'Running: mdfind -onlyin "$expandedPath" \'kMDItemContentType == "com.apple.mail.emlx"\'');

      try {
        final result = await Process.run('mdfind', [
          '-onlyin',
          expandedPath,
          'kMDItemContentType == "com.apple.mail.emlx"',
        ]);

        final stdout = (result.stdout as String).trim();
        final stderr = (result.stderr as String).trim();
        final lines =
            stdout.split('\n').where((l) => l.trim().isNotEmpty).toList();

        // ignore: avoid_print
        print('Exit code: ${result.exitCode}');
        // ignore: avoid_print
        print('Result count: ${lines.length}');
        if (lines.isNotEmpty) {
          // ignore: avoid_print
          print('First 3 results:');
          for (final line in lines.take(3)) {
            // ignore: avoid_print
            print('  $line');
          }
        }
        if (stderr.isNotEmpty) {
          // ignore: avoid_print
          print('Stderr: $stderr');
        }

        // ignore: avoid_print
        print(
            'RESULT: ${lines.isNotEmpty ? "PASS" : "FAIL"} — mdfind (scoped) returned ${lines.length} results');
      } catch (e) {
        // ignore: avoid_print
        print('mdfind error: $e');
        // ignore: avoid_print
        print('RESULT: FAIL — mdfind threw exception');
      }
    });

    test('6. mdfind with unexpanded tilde path (bug check)', () async {
      // This tests if the tilde causes issues
      // ignore: avoid_print
      print(
          'Running: mdfind -onlyin "~/Library/Mail" \'kMDItemContentType == "com.apple.mail.emlx"\'');

      try {
        final result = await Process.run('mdfind', [
          '-onlyin',
          '~/Library/Mail', // NOT expanded — this is what happens if _expandHome fails
          'kMDItemContentType == "com.apple.mail.emlx"',
        ]);

        final stdout = (result.stdout as String).trim();
        final stderr = (result.stderr as String).trim();
        final lines =
            stdout.split('\n').where((l) => l.trim().isNotEmpty).toList();

        // ignore: avoid_print
        print('Exit code: ${result.exitCode}');
        // ignore: avoid_print
        print('Result count: ${lines.length}');
        if (stderr.isNotEmpty) {
          // ignore: avoid_print
          print('Stderr: $stderr');
        }

        // ignore: avoid_print
        print(
            'RESULT: ${result.exitCode == 0 ? "INFO" : "FAIL"} — unexpanded tilde: ${lines.length} results (exit ${result.exitCode})');
      } catch (e) {
        // ignore: avoid_print
        print('mdfind error: $e');
        // ignore: avoid_print
        print('RESULT: FAIL — mdfind threw exception with unexpanded tilde');
      }
    });

    test('7. Alternative content type queries', () async {
      // Try different content type queries to see what works
      final queries = [
        'kMDItemContentType == "com.apple.mail.emlx"',
        'kMDItemContentType == "com.apple.mail.email"',
        'kMDItemKind == "Email Message"',
        'kMDItemFSName == "*.emlx"',
        'kMDItemContentType == "com.apple.mail.emlx"c',
      ];

      for (final query in queries) {
        try {
          final result = await Process.run('mdfind', [query]);
          final stdout = (result.stdout as String).trim();
          final count =
              stdout.split('\n').where((l) => l.trim().isNotEmpty).length;
          // ignore: avoid_print
          print('Query: $query → $count results');
        } catch (e) {
          // ignore: avoid_print
          print('Query: $query → ERROR: $e');
        }
      }

      // ignore: avoid_print
      print('RESULT: INFO — check which queries return results above');
    });

    test('8. Test runMdfind() from mdfind_helpers.dart', () async {
      // Test the actual function used by the production code
      // ignore: avoid_print
      print('Testing runMdfind() with defaultMailDirectory...');

      try {
        final query = buildMdfindQuery();
        // ignore: avoid_print
        print('Query: $query');
        // ignore: avoid_print
        print('Directory: $defaultMailDirectory');

        final results =
            await runMdfind(query, directory: defaultMailDirectory);
        // ignore: avoid_print
        print('Results: ${results.length}');
        if (results.isNotEmpty) {
          // ignore: avoid_print
          print('First 3:');
          for (final r in results.take(3)) {
            // ignore: avoid_print
            print('  $r');
          }
        }

        // ignore: avoid_print
        print(
            'RESULT: ${results.isNotEmpty ? "PASS" : "FAIL"} — runMdfind returned ${results.length} results');
      } catch (e) {
        // ignore: avoid_print
        print('runMdfind error: $e');
        // ignore: avoid_print
        print('RESULT: FAIL — runMdfind threw exception');
      }
    });

    test('9. Test resolveAccountPaths()', () async {
      // ignore: avoid_print
      print('Testing resolveAccountPaths()...');

      try {
        final paths = await resolveAccountPaths();
        // ignore: avoid_print
        print('Found ${paths.length} accounts:');
        for (final entry in paths.entries) {
          final dir = Directory(entry.value);
          final exists = await dir.exists();
          // ignore: avoid_print
          print('  ${entry.key} → ${entry.value} (exists: $exists)');

          // Count .emlx files in this account directory
          if (exists) {
            var count = 0;
            try {
              await for (final f
                  in dir.list(recursive: true, followLinks: false)) {
                if (f is File && f.path.endsWith('.emlx')) {
                  count++;
                  if (count >= 5) break;
                }
              }
            } catch (_) {}
            // ignore: avoid_print
            print('    .emlx files: $count+');
          }
        }

        // ignore: avoid_print
        print(
            'RESULT: ${paths.isNotEmpty ? "PASS" : "FAIL"} — found ${paths.length} accounts');
      } catch (e) {
        // ignore: avoid_print
        print('resolveAccountPaths error: $e');
        // ignore: avoid_print
        print('RESULT: FAIL — resolveAccountPaths threw exception');
      }
    });

    test('10. Test mdfindEmails() high-level function', () async {
      // ignore: avoid_print
      print('Testing mdfindEmails() with no filters...');

      try {
        final results = await mdfindEmails();
        // ignore: avoid_print
        print('Results: ${results.length}');
        if (results.isNotEmpty) {
          // ignore: avoid_print
          print('First 3:');
          for (final r in results.take(3)) {
            // ignore: avoid_print
            print('  $r');
          }
        }

        // ignore: avoid_print
        print(
            'RESULT: ${results.isNotEmpty ? "PASS" : "FAIL"} — mdfindEmails returned ${results.length} results');
      } catch (e) {
        // ignore: avoid_print
        print('mdfindEmails error: $e');
        // ignore: avoid_print
        print('RESULT: FAIL — mdfindEmails threw exception');
      }
    });

    test('11. Test mdfind scoped to account directory', () async {
      // Test scoping to an actual account directory instead of ~/Library/Mail
      try {
        final paths = await resolveAccountPaths();
        if (paths.isEmpty) {
          // ignore: avoid_print
          print('RESULT: SKIP — no accounts');
          return;
        }

        final accountPath = paths.values.first;
        // ignore: avoid_print
        print('Testing mdfind scoped to account: $accountPath');

        final query = buildMdfindQuery();
        final results = await runMdfind(query, directory: accountPath);
        // ignore: avoid_print
        print('Results: ${results.length}');

        // ignore: avoid_print
        print(
            'RESULT: ${results.isNotEmpty ? "PASS" : "FAIL"} — account-scoped mdfind returned ${results.length} results');
      } catch (e) {
        // ignore: avoid_print
        print('Error: $e');
        // ignore: avoid_print
        print('RESULT: FAIL');
      }
    });

    test('12. Check Spotlight indexing status', () async {
      // Check if Spotlight is enabled/disabled for the volume
      // ignore: avoid_print
      print('Checking Spotlight indexing status...');

      try {
        final result =
            await Process.run('mdutil', ['-s', '$homeDir/Library/Mail']);
        // ignore: avoid_print
        print('mdutil -s output: ${(result.stdout as String).trim()}');
        if ((result.stderr as String).trim().isNotEmpty) {
          // ignore: avoid_print
          print('mdutil stderr: ${(result.stderr as String).trim()}');
        }
      } catch (e) {
        // ignore: avoid_print
        print('mdutil error: $e');
      }

      // Also check the root volume
      try {
        final result = await Process.run('mdutil', ['-s', '/']);
        // ignore: avoid_print
        print('mdutil -s / output: ${(result.stdout as String).trim()}');
      } catch (e) {
        // ignore: avoid_print
        print('mdutil / error: $e');
      }

      // ignore: avoid_print
      print('RESULT: INFO — check output above');
    });

    test('13. Verify _expandHome behavior', () async {
      // Manually verify the path expansion logic
      final tildeExpanded = defaultMailDirectory.replaceFirst(
          '~', homeDir);
      // ignore: avoid_print
      print('defaultMailDirectory: $defaultMailDirectory');
      // ignore: avoid_print
      print('After expansion: $tildeExpanded');
      // ignore: avoid_print
      print('Directory exists: ${await Directory(tildeExpanded).exists()}');

      // Check if HOME env var is set
      // ignore: avoid_print
      print('HOME env var: ${Platform.environment['HOME']}');

      // ignore: avoid_print
      print('RESULT: INFO');
    });

    test('14. Test mdfind with date filter', () async {
      // The failing tests use date filters — test if dates cause the issue
      final now = DateTime.now();
      final thirtyDaysAgo = now.subtract(const Duration(days: 30));

      final queryNoDate = 'kMDItemContentType == "com.apple.mail.emlx"';
      final queryWithDate =
          'kMDItemContentType == "com.apple.mail.emlx" && '
          'kMDItemContentCreationDate >= \$time.iso(${thirtyDaysAgo.toUtc().toIso8601String()})';

      // ignore: avoid_print
      print('Query without date: $queryNoDate');
      try {
        final result = await Process.run('mdfind', [queryNoDate]);
        final count = (result.stdout as String)
            .trim()
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .length;
        // ignore: avoid_print
        print('  → $count results');
      } catch (e) {
        // ignore: avoid_print
        print('  → ERROR: $e');
      }

      // ignore: avoid_print
      print('Query with date: $queryWithDate');
      try {
        final result = await Process.run('mdfind', [queryWithDate]);
        final count = (result.stdout as String)
            .trim()
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .length;
        // ignore: avoid_print
        print('  → $count results');
      } catch (e) {
        // ignore: avoid_print
        print('  → ERROR: $e');
      }

      // ignore: avoid_print
      print('RESULT: INFO — compare counts above');
    });
  });
}
