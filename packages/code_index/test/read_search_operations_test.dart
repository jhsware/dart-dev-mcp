import 'dart:convert';
import 'dart:io';

import 'package:code_index_mcp/code_index_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Map<String, dynamic> _json(CallToolResult r) =>
    jsonDecode((r.content.first as TextContent).text) as Map<String, dynamic>;

void main() {
  group('read & search operations (v2, non-Dart records)', () {
    late Directory project;
    late Directory dataDir;
    late String dbPath;
    late Database db;
    late WriteOperations write;
    late BrowseOperations browse;
    late SearchOperations search;
    late SymbolQueries symbols;
    late GraphQueries graph;

    void write0(String relPath, String contents) {
      final f = File(p.join(project.path, relPath));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(contents);
    }

    setUp(() async {
      project = Directory.systemTemp.createTempSync('rs_project_');
      dataDir = Directory.systemTemp.createTempSync('rs_data_');
      dbPath = p.join(dataDir.path, 'code_index.db');
      db = initializeDatabase(dbPath);
      write = WriteOperations(database: db, workingDir: project);
      browse = BrowseOperations(
          database: db, workingDir: project, dbPath: dbPath);
      search = SearchOperations(database: db, workingDir: project);
      symbols = SymbolQueries(database: db, workingDir: project);
      graph = GraphQueries(database: db, workingDir: project);

      write0('config/app.yaml',
          'server:\n  host: localhost\n  port: 8080\nsecret: xxx\nextra: 1\n');
      write0('shared/base.yaml', 'defaults:\n  retries: 3\n');

      await write.indexFiles({
        'files': [
          {
            'path': 'config/app.yaml',
            'language': 'yaml',
            'summary': 'App configuration for auth login',
            'tags': ['auth', 'login', 'config'],
            'symbols': [
              {
                'name': 'server',
                'kind': 'key',
                'visibility': 'public',
                'line': 1,
                'end_line': 3,
                'summary': 'The server block.'
              },
              {
                'name': '_secret',
                'kind': 'key',
                'visibility': 'private',
                'line': 4,
                'end_line': 4
              },
            ],
            'imports': ['shared/base.yaml'],
            'references': [
              {
                'symbol': 'Widget',
                'qualifier': 'package:flutter/material.dart',
                'count': 3
              },
            ],
            'annotations': [
              {'kind': 'TODO', 'message': 'add https', 'line': 2},
            ],
          },
          {
            'path': 'shared/base.yaml',
            'language': 'yaml',
            'summary': 'Base shared config',
            'tags': ['config', 'base'],
            'symbols': [
              {
                'name': 'defaults',
                'kind': 'key',
                'visibility': 'public',
                'line': 1,
                'end_line': 2
              },
            ],
          },
        ],
        'refresh_dependents': false,
      });
    });

    tearDown(() {
      db.dispose();
      project.deleteSync(recursive: true);
      dataDir.deleteSync(recursive: true);
    });

    test('get-file default layers [0,1,4]: metadata, summary/tags, public API',
        () {
      final res = _json(browse.getFile({'path': 'config/app.yaml'}));
      expect(res['line_count'], isNotNull);
      expect(res['analysis_status'], 'fresh');
      expect(res['summary'], contains('auth'));
      expect(res['tags'], containsAll(<String>['auth', 'login']));
      final names =
          (res['symbols'] as List).map((s) => s['name']).toList();
      expect(names, contains('server'));
      expect(names, isNot(contains('_secret'))); // public-only
      expect(res['imports'], contains('shared/base.yaml'));
      expect(res.containsKey('references'), isFalse); // no layer 2/3
      expect(res['needs_reindex'], isEmpty);
    });

    test('get-file layer 2: all symbols + references (dot_path, resolution)',
        () {
      final res = _json(browse.getFile({
        'path': 'config/app.yaml',
        'layers': [2],
      }));
      final names =
          (res['symbols'] as List).map((s) => s['name']).toList();
      expect(names, containsAll(<String>['server', '_secret']));
      // layer 2 has line ranges but not summaries.
      final server = (res['symbols'] as List)
          .firstWhere((s) => s['name'] == 'server') as Map;
      expect(server['line'], 1);
      expect(server['end_line'], 3);
      expect(server.containsKey('summary'), isFalse);
      final refs = res['references'] as List;
      expect(refs.single['dot_path'], 'flutter.material.Widget');
      expect(refs.single['resolution'], 'declared');
      expect((res['annotations'] as List).single['kind'], 'TODO');
    });

    test('get-file layer 3: symbol summaries included', () {
      final res = _json(browse.getFile({
        'path': 'config/app.yaml',
        'layers': [3],
      }));
      final server = (res['symbols'] as List)
          .firstWhere((s) => s['name'] == 'server') as Map;
      expect(server['summary'], 'The server block.');
    });

    test('get-file missing file returns needs_reindex', () {
      final res = _json(browse.getFile({'path': 'nope.yaml'}));
      expect(res['error'], contains('not found'));
      expect((res['needs_reindex'] as List).single['path'], 'nope.yaml');
    });

    test('overview: path, summary, tags, line_count, public symbol names', () {
      final res = _json(browse.overview({'file_type': 'yaml'}));
      expect(res['count'], 2);
      final app = (res['files'] as List)
          .firstWhere((f) => f['path'] == 'config/app.yaml') as Map;
      expect(app['summary'], contains('auth'));
      expect(app['tags'], contains('config'));
      expect(app['line_count'], isNotNull);
      expect(app['symbols'], contains('server'));
      expect(app['symbols'], isNot(contains('_secret')));
    });

    test('project-info: schema version, row counts, last_scan_at, db path', () {
      final res = _json(browse.projectInfo({}));
      expect(res['schema_version'], 2);
      expect((res['row_counts'] as Map)['files'], 2);
      expect((res['row_counts'] as Map)['symbol_references'], 1);
      expect(res['last_scan_at'], isNotNull);
      expect(res['db_path'], dbPath);
    });

    test('search: FTS query + tag + symbol_name filters', () {
      final byQuery = _json(search.search({'query': 'auth login'}));
      expect((byQuery['files'] as List).map((f) => f['path']),
          contains('config/app.yaml'));

      final byTag = _json(search.search({'tag': 'auth'}));
      expect((byTag['files'] as List).single['path'], 'config/app.yaml');

      final bySymbol = _json(search.search({'symbol_name': 'server'}));
      expect((bySymbol['files'] as List).single['path'], 'config/app.yaml');
    });

    test('search: LIKE fallback on malformed FTS query', () {
      // Whitespace-only query yields an empty FTS MATCH string, which FTS5
      // rejects → the handler retries with a LIKE scan.
      final res = _json(search.search({'query': '   '}));
      expect((res['filters'] as Map)['fallback'], 'like');
    });

    test('find-symbol: exact + prefix + visibility, returns line range', () {
      final exact = _json(symbols.findSymbol({'name': 'server'}));
      final m = (exact['matches'] as List).single as Map;
      expect(m['path'], 'config/app.yaml');
      expect(m['line'], 1);
      expect(m['end_line'], 3);
      expect(m['kind'], 'key');

      final prefix = _json(
          symbols.findSymbol({'name': 'serv', 'match': 'prefix'}));
      expect((prefix['matches'] as List).map((e) => e['name']),
          contains('server'));

      final priv = _json(symbols
          .findSymbol({'name': '_secret', 'visibility': 'private'}));
      expect((priv['matches'] as List).single['visibility'], 'private');
    });

    test('references: symbol lookup + resolution filter', () {
      final all = _json(symbols.references({'symbol': 'Widget'}));
      final m = (all['matches'] as List).single as Map;
      expect(m['dot_path'], 'flutter.material.Widget');
      expect(m['resolution'], 'declared');
      expect(m['count'], 3);

      final resolved = _json(symbols.references({'resolution': 'resolved'}));
      expect(resolved['matches'], isEmpty);
    });

    test('dependents: files importing a path with matching imports', () {
      final res = _json(graph.dependents({'path': 'shared/base.yaml'}));
      final dep = (res['dependents'] as List).single as Map;
      expect(dep['path'], 'config/app.yaml');
      expect(dep['matching_imports'], contains('shared/base.yaml'));
    });

    test('dependencies: internal vs external classification', () {
      final res = _json(graph.dependencies({'path': 'config/app.yaml'}));
      expect(res['internal_count'], 1);
      expect(res['external_count'], 0);
      final dep = (res['dependencies'] as List).single as Map;
      expect(dep['classification'], 'internal');
      expect(dep['resolved_path'], 'shared/base.yaml');
    });

    test('annotations: kind filter + by_kind counts', () {
      final res = _json(graph.annotations({'kind': 'TODO'}));
      expect(res['count'], 1);
      expect((res['by_kind'] as Map)['TODO'], 1);
      expect((res['annotations'] as List).single['path'], 'config/app.yaml');
    });

    test('stats: aggregates, tag cloud, freshness', () {
      final res = _json(search.stats({}));
      expect((res['files'] as Map)['total'], 2);
      expect(((res['files'] as Map)['by_type'] as Map)['yaml'], 2);
      expect(((res['symbols'] as Map)['by_kind'] as Map)['key'], 3);
      expect((res['freshness'] as Map)['fresh'], 2);
      final tags = (res['tags'] as List).map((t) => t['tag']).toList();
      expect(tags, contains('config'));
      final topRefs =
          (res['references'] as Map)['top'] as List;
      expect(topRefs.single['dot_path'], 'flutter.material.Widget');
    });
  });
}
