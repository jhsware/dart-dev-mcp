import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:planner_remote_mcp/planner_remote_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

/// Decode the text payload of a CallToolResult.
String _resultText(CallToolResult r) => (r.content.first as TextContent).text;

void main() {
  group('PlannerRemoteConfig.parse', () {
    test('parses repeated project dirs and trims trailing slashes', () {
      final c = PlannerRemoteConfig.parse([
        '--project-dir=/a/one',
        '--project-dir=/b/two',
        '--server-url=https://h:9444///',
        '--token=abc',
      ]);
      expect(c.projectDirs, ['/a/one', '/b/two']);
      expect(c.serverUrl, 'https://h:9444');
      expect(c.token, 'abc');
      expect(c.insecure, isFalse);
    });

    test('--insecure flag', () {
      final c = PlannerRemoteConfig.parse(
          ['--project-dir=/a', '--server-url=https://h', '--insecure']);
      expect(c.insecure, isTrue);
    });
  });

  group('dispatchPlanner mapping', () {
    late HttpServer server;
    late PlannerApiClient client;
    late PlannerRemoteConfig config;
    const projectDir = '/tmp/myproj';

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final path = '${req.uri.path}'
            '${req.uri.hasQuery ? '?${req.uri.query}' : ''}';
        final body = await utf8.decoder.bind(req).join();
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          '_method': req.method,
          '_path': path,
          '_body': body.isEmpty ? null : jsonDecode(body),
          'ok': true,
        }));
        await req.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      config = PlannerRemoteConfig.parse(
          ['--project-dir=$projectDir', '--server-url=$base']);
      client = PlannerApiClient(baseUrl: base, client: http.Client());
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    Future<Map<String, dynamic>> call(Map<String, dynamic> args) async {
      final r = await dispatchPlanner(args, client, config);
      return jsonDecode(_resultText(r)) as Map<String, dynamic>;
    }

    test('list-projects is answered locally', () async {
      final r = await call({'operation': 'list-projects'});
      expect(r['count'], 1);
      expect((r['projects'] as List).first['project_name'], 'myproj');
    });

    test('rejects unknown project_dir', () async {
      final r = await dispatchPlanner(
          {'operation': 'show-task', 'project_dir': '/nope', 'id': 'x'},
          client,
          config);
      expect(_resultText(r), startsWith('Error:'));
    });

    test('add-task -> POST /projects/myproj/tasks', () async {
      final r = await call({
        'operation': 'add-task',
        'project_dir': projectDir,
        'title': 'T',
        'status': 'todo',
      });
      expect(r['_method'], 'POST');
      expect(r['_path'], '/projects/myproj/tasks');
      expect(r['_body'], {'title': 'T', 'status': 'todo'});
      expect(r['project_dir'], projectDir);
    });

    test('show-task -> GET /projects/myproj/tasks/{id}', () async {
      final r = await call(
          {'operation': 'show-task', 'project_dir': projectDir, 'id': 't1'});
      expect(r['_method'], 'GET');
      expect(r['_path'], '/projects/myproj/tasks/t1');
    });

    test('list-tasks builds query string', () async {
      final r = await call({
        'operation': 'list-tasks',
        'project_dir': projectDir,
        'status': 'todo',
        'limit': 5,
      });
      expect(r['_path'], '/projects/myproj/tasks?status=todo&limit=5');
    });

    test('add-step -> POST under the task', () async {
      final r = await call({
        'operation': 'add-step',
        'project_dir': projectDir,
        'task_id': 't1',
        'title': 'S',
      });
      expect(r['_method'], 'POST');
      expect(r['_path'], '/projects/myproj/tasks/t1/steps');
    });

    test('add-item-to-slate -> PUT linkage path', () async {
      final r = await call({
        'operation': 'add-item-to-slate',
        'project_dir': projectDir,
        'release_id': 's1',
        'item_id': 'i1',
      });
      expect(r['_method'], 'PUT');
      expect(r['_path'], '/projects/myproj/slates/s1/items/i1');
    });

    test('get-audit-trail -> GET audit path', () async {
      final r = await call({
        'operation': 'get-audit-trail',
        'project_dir': projectDir,
        'entity_type': 'task',
        'id': 't1',
      });
      expect(r['_method'], 'GET');
      expect(r['_path'], '/projects/myproj/audit/task/t1');
    });
  });
}
