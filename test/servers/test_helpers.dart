import 'dart:convert';
import 'dart:io';

/// All server scripts available for compilation
const serverScripts = [
  'bin/file_edit_mcp.dart',
  'bin/convert_to_md_mcp.dart',
  'bin/fetch_mcp.dart',
  'bin/dart_runner_mcp.dart',
  'bin/flutter_runner_mcp.dart',
  'bin/git_mcp.dart',
  'bin/planner_mcp.dart',
  'bin/code_index_mcp.dart',
];

/// Compiles a Dart script to kernel format (.dill) for faster execution.
/// The .dill files are cached on disk and reused across test runs.
Future<String> compileToKernel(String scriptPath) async {
  final dillPath = scriptPath.replaceAll('.dart', '.dill');
  final dillFile = File(dillPath);
  final sourceFile = File(scriptPath);

  // Skip compilation if .dill exists and is newer than source
  if (await dillFile.exists()) {
    final dillMod = await dillFile.lastModified();
    final sourceMod = await sourceFile.lastModified();
    if (dillMod.isAfter(sourceMod)) {
      return dillPath;
    }
  }

  final result = await Process.run(
    'dart',
    ['compile', 'kernel', scriptPath, '-o', dillPath],
    workingDirectory: Directory.current.path,
  );

  if (result.exitCode != 0) {
    throw Exception('Failed to compile $scriptPath: ${result.stderr}');
  }

  return dillPath;
}

/// Compile all server scripts in parallel.
/// Call this in setUpAll() for optimal performance.
Future<void> compileAllServers() async {
  await Future.wait(serverScripts.map(compileToKernel));
}

/// Starts a server and waits for it to be ready.
/// Returns the process and stderr buffer for verification.
Future<(Process, StringBuffer)> startServer(
  String scriptPath,
  List<String> args,
) async {
  final dillPath = await compileToKernel(scriptPath);

  final process = await Process.start(
    'dart',
    ['run', dillPath, ...args],
    workingDirectory: Directory.current.path,
  );

  final stderrBuffer = StringBuffer();
  var complete = false;

  process.stderr.transform(utf8.decoder).listen((data) {
    stderrBuffer.write(data);
    if (data.contains('running on stdio')) {
      complete = true;
    }
  });

  // Drain stdout to prevent blocking
  process.stdout.transform(utf8.decoder).listen((_) {});

  // Wait for startup with short polling interval
  final startTime = DateTime.now();
  while (!complete && DateTime.now().difference(startTime).inSeconds < 5) {
    await Future.delayed(Duration(milliseconds: 20));
  }

  return (process, stderrBuffer);
}

/// Runs a compiled server synchronously and returns the result.
Future<ProcessResult> runServer(
  String scriptPath,
  List<String> args,
) async {
  final dillPath = await compileToKernel(scriptPath);
  return Process.run(
    'dart',
    ['run', dillPath, ...args],
    workingDirectory: Directory.current.path,
  );
}

/// Stops a server process gracefully.
Future<void> stopServer(Process process) async {
  process.kill(ProcessSignal.sigterm);
  await process.exitCode.timeout(
    Duration(seconds: 2),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
}
