@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:apple_mail_mcp/apple_mail_mcp.dart';
import 'package:test/test.dart';

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

      var emlxCount = 0;
      String? firstEmlxPath;

      try {
        await for (final entity
            in mailDir.list(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.endsWith('.emlx')) {
            emlxCount++;
            firstEmlxPath ??= entity.path;
            if (emlxCount >= 10) break;
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

    test('4. Raw mdfind — simplest possible query (no scoping)', () async {
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

    test('5. mdfind with -name flag for .emlx files', () async {
      // From cheat sheet: -name flag searches file names only
      // ignore: avoid_print
      print('Running: mdfind -name ".emlx"');

      try {
        final result = await Process.run('mdfind', ['-name', '.emlx']);

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
            'RESULT: ${lines.isNotEmpty ? "PASS" : "FAIL"} — mdfind -name returned ${lines.length} results');
      } catch (e) {
        // ignore: avoid_print
        print('mdfind error: $e');
      }
    });

    test('6. mdfind with kMDItemFSName (single quotes)', () async {
      // From cheat sheet: kMDItemFSName uses single quotes inside double quotes
      // ignore: avoid_print
      print('Running: mdfind "kMDItemFSName == \'*.emlx\'"');

      try {
        final result = await Process.run('mdfind', [
          "kMDItemFSName == '*.emlx'",
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
            'RESULT: ${lines.isNotEmpty ? "PASS" : "FAIL"} — kMDItemFSName returned ${lines.length} results');
      } catch (e) {
        // ignore: avoid_print
        print('mdfind error: $e');
      }
    });

    test('7. mdfind with kind:email (cheat sheet syntax)', () async {
      // From cheat sheet: kind:email should find email messages
      // ignore: avoid_print
      print('Running: mdfind kind:email');

      try {
        final result = await Process.run('mdfind', ['kind:email']);

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
            'RESULT: ${lines.isNotEmpty ? "PASS" : "FAIL"} — kind:email returned ${lines.length} results');
      } catch (e) {
        // ignore: avoid_print
        print('mdfind error: $e');
      }
    });

    test('8. mdfind with -onlyin expanded path', () async {
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
      }
    });

    test('9. mdfind with unexpanded tilde path (bug check)', () async {
      // ignore: avoid_print
      print(
          'Running: mdfind -onlyin "~/Library/Mail" \'kMDItemContentType == "com.apple.mail.emlx"\'');

      try {
        final result = await Process.run('mdfind', [
          '-onlyin',
          '~/Library/Mail',
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
      }
    });

    test('10. Check Spotlight privacy exclusion list', () async {
      // Check if ~/Library/Mail/ is excluded from Spotlight indexing
      // ignore: avoid_print
      print('Checking Spotlight privacy exclusions...');

      // The privacy list is stored in Spotlight preferences
      try {
        final result = await Process.run('defaults', [
          'read',
          '/.Spotlight-V100/VolumeConfiguration',
          'Exclusions',
        ]);
        // ignore: avoid_print
        print('Volume exclusions: ${(result.stdout as String).trim()}');
        if ((result.stderr as String).trim().isNotEmpty) {
          // ignore: avoid_print
          print('Stderr: ${(result.stderr as String).trim()}');
        }
      } catch (e) {
        // ignore: avoid_print
        print('Could not read volume exclusions: $e');
      }

      // Also check user-level Spotlight privacy
      try {
        final result = await Process.run('defaults', [
          'read',
          'com.apple.Spotlight',
          'Exclusions',
        ]);
        // ignore: avoid_print
        print('User exclusions: ${(result.stdout as String).trim()}');
      } catch (e) {
        // ignore: avoid_print
        print('No user exclusions or error: $e');
      }

      // Check mdutil status
      try {
        final result =
            await Process.run('mdutil', ['-s', '$homeDir/Library/Mail']);
        // ignore: avoid_print
        print('mdutil -s Mail: ${(result.stdout as String).trim()}');
        if ((result.stderr as String).trim().isNotEmpty) {
          // ignore: avoid_print
          print('mdutil stderr: ${(result.stderr as String).trim()}');
        }
      } catch (e) {
        // ignore: avoid_print
        print('mdutil error: $e');
      }

      try {
        final result = await Process.run('mdutil', ['-s', '/']);
        // ignore: avoid_print
        print('mdutil -s /: ${(result.stdout as String).trim()}');
      } catch (e) {
        // ignore: avoid_print
        print('mdutil / error: $e');
      }

      // ignore: avoid_print
      print('RESULT: INFO — check output above');
    });

    test('11. Test resolveAccountPaths()', () async {
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

    test('12. mdfind scoped to account directory', () async {
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

        // Test with content type query
        final query = buildMdfindQuery();
        final results = await runMdfind(query, directory: accountPath);
        // ignore: avoid_print
        print('Content type query results: ${results.length}');

        // Test with -name flag scoped to account
        final result2 = await Process.run('mdfind', [
          '-onlyin', accountPath, '-name', '.emlx',
        ]);
        final nameResults = (result2.stdout as String).trim()
            .split('\n').where((l) => l.trim().isNotEmpty).toList();
        // ignore: avoid_print
        print('-name .emlx results: ${nameResults.length}');

        // Test with kMDItemFSName scoped to account
        final result3 = await Process.run('mdfind', [
          '-onlyin', accountPath, "kMDItemFSName == '*.emlx'",
        ]);
        final fsNameResults = (result3.stdout as String).trim()
            .split('\n').where((l) => l.trim().isNotEmpty).toList();
        // ignore: avoid_print
        print('kMDItemFSName results: ${fsNameResults.length}');

        // ignore: avoid_print
        print('RESULT: INFO — compare counts above');
      } catch (e) {
        // ignore: avoid_print
        print('Error: $e');
        // ignore: avoid_print
        print('RESULT: FAIL');
      }
    });

    test('13. mdfind with -interpret flag', () async {
      // The -interpret flag uses natural language interpretation
      // ignore: avoid_print
      print('Running: mdfind -interpret "email messages"');

      try {
        final result = await Process.run('mdfind', [
          '-interpret', 'email messages',
        ]);

        final stdout = (result.stdout as String).trim();
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

        // ignore: avoid_print
        print(
            'RESULT: ${lines.isNotEmpty ? "PASS" : "FAIL"} — -interpret returned ${lines.length} results');
      } catch (e) {
        // ignore: avoid_print
        print('mdfind error: $e');
      }
    });

    test('14. mdfind for ANY file in ~/Library/Mail (test FDA)', () async {
      // This tests if mdfind can access ANYTHING in ~/Library/Mail
      // If even a wildcard search returns 0 results, FDA is the blocker
      final expandedPath = '$homeDir/Library/Mail';
      // ignore: avoid_print
      print('Running: mdfind -onlyin "$expandedPath" "*"');

      try {
        final result = await Process.run('mdfind', [
          '-onlyin', expandedPath, '*',
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
        if (lines.isNotEmpty) {
          // ignore: avoid_print
          print('First 3 results:');
          for (final line in lines.take(3)) {
            // ignore: avoid_print
            print('  $line');
          }
        }

        // ignore: avoid_print
        print(
            'RESULT: ${lines.isNotEmpty ? "PASS" : "FAIL"} — wildcard in ~/Library/Mail returned ${lines.length} results');
      } catch (e) {
        // ignore: avoid_print
        print('mdfind error: $e');
      }
    });

    test('15. mdfind for .emlx OUTSIDE ~/Library/Mail', () async {
      // Test if mdfind works at all for .emlx files anywhere on disk
      // If this returns results but scoped search doesn't, it's a scoping issue
      // ignore: avoid_print
      print('Running: mdfind -onlyin / \'kMDItemContentType == "com.apple.mail.emlx"\' (first 5 only)');

      try {
        final result = await Process.run('mdfind', [
          'kMDItemContentType == "com.apple.mail.emlx"',
        ]);

        final stdout = (result.stdout as String).trim();
        final lines =
            stdout.split('\n').where((l) => l.trim().isNotEmpty).toList();

        // Separate by location
        final inMail = lines.where((l) => l.contains('/Library/Mail/')).length;
        final outsideMail = lines.where((l) => !l.contains('/Library/Mail/')).length;

        // ignore: avoid_print
        print('Total results: ${lines.length}');
        // ignore: avoid_print
        print('  In ~/Library/Mail: $inMail');
        // ignore: avoid_print
        print('  Outside ~/Library/Mail: $outsideMail');

        if (lines.isNotEmpty) {
          // ignore: avoid_print
          print('First 5 results:');
          for (final line in lines.take(5)) {
            // ignore: avoid_print
            print('  $line');
          }
        }

        // ignore: avoid_print
        print(
            'RESULT: INFO — total=${lines.length}, inMail=$inMail, outside=$outsideMail');
      } catch (e) {
        // ignore: avoid_print
        print('mdfind error: $e');
      }
    });

    test('16. Compare mdfind vs direct listing counts', () async {
      // If mdfind returns 0 but filesystem listing finds files,
      // the issue is Spotlight indexing, not FDA
      final mailDir = Directory('$homeDir/Library/Mail');
      if (!await mailDir.exists()) {
        // ignore: avoid_print
        print('RESULT: SKIP — ~/Library/Mail does not exist');
        return;
      }

      var fsCount = 0;
      try {
        await for (final entity
            in mailDir.list(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.endsWith('.emlx')) {
            fsCount++;
            if (fsCount >= 100) break;
          }
        }
      } catch (e) {
        // ignore: avoid_print
        print('Filesystem error: $e');
      }

      int mdfindCount;
      try {
        final result = await Process.run('mdfind', [
          '-onlyin', '$homeDir/Library/Mail',
          'kMDItemContentType == "com.apple.mail.emlx"',
        ]);
        final lines = (result.stdout as String).trim()
            .split('\n').where((l) => l.trim().isNotEmpty).toList();
        mdfindCount = lines.length;
      } catch (_) {
        mdfindCount = -1;
      }

      // ignore: avoid_print
      print('Filesystem count: $fsCount+ .emlx files');
      // ignore: avoid_print
      print('mdfind count: $mdfindCount .emlx files');

      if (fsCount > 0 && mdfindCount == 0) {
        // ignore: avoid_print
        print('DIAGNOSIS: Files exist but mdfind can\'t find them');
        // ignore: avoid_print
        print('  → Likely cause: Spotlight index issue or FDA blocking mdfind');
      } else if (fsCount == 0 && mdfindCount == 0) {
        // ignore: avoid_print
        print('DIAGNOSIS: No .emlx files found by either method');
        // ignore: avoid_print
        print('  → Likely cause: FDA blocking both filesystem and Spotlight');
      } else if (fsCount > 0 && mdfindCount > 0) {
        // ignore: avoid_print
        print('DIAGNOSIS: Both methods work — mdfind is functional');
      }

      // ignore: avoid_print
      print('RESULT: INFO — fs=$fsCount, mdfind=$mdfindCount');
    });
  });
}
