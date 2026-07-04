import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_helpers.dart';

/// Scope enforcement (design §9): when `--allowed-paths` is set, every handler
/// must refuse work outside the allow-list. Reads (`get-file`, `search`) return
/// an `out_of_scope` envelope, `scan` collects out-of-scope files, and the
/// `index-files` write path records them under `failed[]`.
void main() {
  late TestIndex idx;

  setUp(() {
    idx = TestIndex.create();
    idx.writeFile('lib/app.yaml', 'name: app\n');
    idx.writeFile('bin/tool.yaml', 'name: tool\n');
    idx.restrict([p.join(idx.project.path, 'lib')]);
  });

  tearDown(() => idx.dispose());

  test('get-file refuses an out-of-scope path', () {
    final res = jsonOf(idx.browse.getFile({'path': 'bin/tool.yaml'}));
    expect(res['status'], 'out_of_scope');
    expect(res['path'], 'bin/tool.yaml');
    expect(res['allowed_paths'], contains('lib'));
    expect(res['message'], contains('outside allowed paths'));
  });

  test('get-file allows an in-scope path (file simply not indexed yet)', () {
    final res = jsonOf(idx.browse.getFile({'path': 'lib/app.yaml'}));
    // In scope: no out_of_scope envelope. Not indexed → not-found envelope.
    expect(res.containsKey('status'), isFalse);
    expect(res['error'], contains('not found'));
  });

  test('search refuses an out-of-scope path_pattern', () {
    final res = jsonOf(idx.search.search({'path_pattern': 'bin/tool.yaml'}));
    expect(res['status'], 'out_of_scope');
  });

  test('scan collects out-of-scope files instead of planning them', () {
    final res = idx.scanDirs();
    expect(res['out_of_scope'], contains('bin/tool.yaml'));
    final planned =
        (res['plan'] as List).map((e) => e['path'] as String).toList();
    expect(planned, isNot(contains('bin/tool.yaml')));
    expect(planned, contains('lib/app.yaml'));
  });

  test('index-files records an out-of-scope write under failed[]', () async {
    final res = await idx.indexFiles([
      {'path': 'lib/app.yaml', 'language': 'yaml'},
      {'path': 'bin/tool.yaml', 'language': 'yaml'},
    ]);
    expect(res['indexed'], contains('lib/app.yaml'));
    expect(res['indexed'], isNot(contains('bin/tool.yaml')));
    final failed = (res['failed'] as List).cast<Map<String, dynamic>>();
    final tool = failed.firstWhere((f) => f['path'] == 'bin/tool.yaml');
    expect(tool['error'], contains('Out of scope'));
  });
}
