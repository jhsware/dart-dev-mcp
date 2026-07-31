import 'dart:convert';

import 'package:jhsware_code_shared_libs/shared_libs.dart'
    show resolveProjectDirAlias;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;

import 'api_client.dart';
import 'config.dart';

const validOperations = [
  'list-projects',
  'create-project',
  'get-project-instructions',
  'add-task',
  'show-task',
  'update-task',
  'show-task-memory',
  'update-task-memory',
  'list-tasks',
  'add-step',
  'show-step',
  'update-step',
  'get-subtask-prompt',
  'add-item',
  'show-item',
  'update-item',
  'list-items',
  'add-slate',
  'show-slate',
  'update-slate',
  'list-slates',
  'add-item-to-slate',
  'remove-item-from-slate',
  'add-item-to-task',
  'remove-item-from-task',
  'log-commit',
  'log-merge',
  'get-timeline',
  'get-audit-trail',
];

CallToolResult _json(Map<String, dynamic> data) => CallToolResult.fromContent([
  TextContent(text: const JsonEncoder.withIndent('  ').convert(data)),
]);

CallToolResult _text(String text) =>
    CallToolResult.fromContent([TextContent(text: text)]);

/// Register the `planner` tool. The schema mirrors the local planner MCP
/// exactly so agent prompts and skills need no changes.
void registerPlannerTool(
  McpServer server,
  PlannerApiClient client,
  PlannerConfig config,
) {
  server.registerTool(
    'planner',
    description:
        '''Task and step management for AI-assisted development (remote: backed by planner_server).

Operations:
- list-projects: List all registered project directories with their short names. Takes no arguments. Returns project_dir (full path) and project_name (basename) for each.
- create-project: Create/register a project from a local files folder path on the server. Requires: local_path. Optional: name. Idempotent/additive; does not require project_dir.
- get-project-instructions: Read project instructions from AGENTS.md
- add-task: Create a new task
- show-task: Show task details with list of steps and linked backlog items. Requires: id.
- update-task: Update task properties
- show-task-memory: Show task memory/notes
- update-task-memory: Update task memory/notes
- list-tasks: List all tasks (optional filter: status). Pagination: start_at (default 0), limit (default 30, max 100).
- add-step: Add a step to a task. Use sub_task_id to link the step to a sub-task (parent task pattern).
- show-step: Show step details
- update-step: Update step properties
- get-subtask-prompt: Get the sub-task details for a step in a parent task. Requires: id (step ID).
- add-item: Create a backlog item. Requires: title. Optional: details, type, status.
- show-item: Show item details with edit history, linked tasks and slates. Requires: id.
- update-item: Update item fields. Requires: id.
- list-items: List items with filters. Optional: search_query, type, status, backlog_only. Pagination: start_at, limit.
- add-slate: Create a slate. Requires: title. Optional: notes, status, release_date.
- show-slate: Show slate with its items. Requires: id.
- update-slate: Update slate fields. Requires: id.
- list-slates: List slates. Optional: status. Pagination: start_at, limit.
- add-item-to-slate: Assign item to slate. Requires: release_id, item_id.
- remove-item-from-slate: Remove item from slate. Requires: release_id, item_id.
- add-item-to-task: Link a backlog item to a task. Requires: task_id, item_id.
- remove-item-from-task: Unlink a backlog item from a task. Requires: task_id, item_id.
- log-commit: Log a git commit to the timeline. Requires: commit_hash, branch, task_id. Optional: step_id, message.
- log-merge: Log a git branch merge. Requires: commit_hash, source_branch, target_branch, task_id.
- get-timeline: Get recent activity timeline (optional: limit, entity_type, before, after)
- get-audit-trail: Get detailed change history for an entity (requires: entity_type, id)

Task statuses: backlog, todo, draft, started, canceled, done, merged
Step statuses: todo, started, canceled, done
Item types: feature, improvement, bug, change, investigation
Item statuses: open, closed, archived
Slate statuses: draft, todo, started, done, released

Parent task pattern: Prefix parent task title with "Parent:". Each step references a sub-task via sub_task_id. Use get-subtask-prompt to fetch the sub-task details for a step.''',
    inputSchema: ToolInputSchema(
      properties: {
        'project_dir': JsonSchema.string(
          description:
              'Project directory path. Must match one of the registered --project-dir values. Required for every operation EXCEPT list-projects and create-project.',
        ),
        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: validOperations,
        ),
        'local_path': JsonSchema.string(
          description:
              'Absolute path to the project local files folder (create-project).',
        ),
        'name': JsonSchema.string(
          description:
              'Optional project name (create-project); defaults to folder basename.',
        ),
        'id': JsonSchema.string(
          description: 'Task or step ID (for show/update/audit-trail)',
        ),
        'task_id': JsonSchema.string(
          description: 'Parent task ID (for add-step, log-commit, log-merge)',
        ),
        'title': JsonSchema.string(description: 'Title for task or step'),
        'details': JsonSchema.string(
          description: 'Detailed description for task or step',
        ),
        'sub_task_id': JsonSchema.string(
          description: 'Optional reference to another task ID (sub-task).',
        ),
        'status': JsonSchema.string(
          description:
              'Status for tasks/steps/items/slates. Also used for list filters.',
          enumValues: [
            'backlog',
            'todo',
            'draft',
            'started',
            'canceled',
            'done',
            'merged',
            'open',
            'closed',
            'archived',
            'released',
          ],
        ),
        'memory': JsonSchema.string(
          description: 'Memory/notes content for task',
        ),
        'entity_type': JsonSchema.string(
          description: "Entity type: 'task', 'step', 'item', or 'slate'",
          enumValues: ['task', 'step', 'item', 'slate'],
        ),
        'limit': JsonSchema.integer(description: 'Maximum entries to return.'),
        'start_at': JsonSchema.integer(
          description: 'Zero-based offset for list ops.',
        ),
        'before': JsonSchema.string(
          description: 'Return entries before this ISO datetime (get-timeline)',
        ),
        'after': JsonSchema.string(
          description: 'Return entries after this ISO datetime (get-timeline)',
        ),
        'commit_hash': JsonSchema.string(
          description: 'Git commit hash (log-commit/merge)',
        ),
        'branch': JsonSchema.string(
          description: 'Git branch name (log-commit)',
        ),
        'source_branch': JsonSchema.string(
          description: 'Source branch (log-merge)',
        ),
        'target_branch': JsonSchema.string(
          description: 'Target branch (log-merge)',
        ),
        'message': JsonSchema.string(
          description: 'Commit message (log-commit)',
        ),
        'step_id': JsonSchema.string(description: 'Step ID (log-commit)'),
        'type': JsonSchema.string(
          description: 'Item type',
          enumValues: [
            'feature',
            'improvement',
            'bug',
            'change',
            'investigation',
          ],
        ),
        'notes': JsonSchema.string(description: 'Slate notes (markdown)'),
        'search_query': JsonSchema.string(
          description: 'Search query for list-items',
        ),
        'release_id': JsonSchema.string(
          description: 'Slate ID (for add/remove-item-to/from-slate)',
        ),
        'item_id': JsonSchema.string(description: 'Item ID (for linkage ops)'),
        'release_date': JsonSchema.string(
          description: 'Target slate date in ISO 8601 (add/update-slate)',
        ),
        'backlog_only': JsonSchema.boolean(
          description: 'list-items: only items not in any slate',
        ),
      },
      required: [],
    ),
    callback: (args, extra) => dispatchPlanner(args, client, config),
  );
}

/// Dispatch a single planner operation to planner_server. Exposed for testing;
/// the registered tool callback delegates here.
Future<CallToolResult> dispatchPlanner(
  Map<String, dynamic> args,
  PlannerApiClient client,
  PlannerConfig config,
) async {
  final operation = args['operation'] as String?;
  if (operation == null || !validOperations.contains(operation)) {
    return _text(
      'Error: operation must be one of: ${validOperations.join(', ')}',
    );
  }

  if (operation == 'list-projects') {
    final projects = config.projectDirs
        .map((d) => {'project_dir': d, 'project_name': p.basename(d)})
        .toList();
    return _json({'projects': projects, 'count': projects.length});
  }

  if (operation == 'create-project') {
    final localPath = (args['local_path'] as String?)?.trim();
    if (localPath == null || localPath.isEmpty) {
      return _text('Error: local_path is required');
    }
    try {
      final name = args['name'] as String?;
      final body = {
        'local_path': localPath,
        if (name != null && name.isNotEmpty) 'name': name,
      };
      return _json(await client.requestJson('POST', '/projects', body: body));
    } on PlannerHttpException catch (e) {
      return _text('Error: ${e.message}');
    } catch (e) {
      return _text('Error: $e');
    }
  }
  final requestedDir = args['project_dir'] as String?;
  if (requestedDir == null || requestedDir.isEmpty) {
    return _text('Error: project_dir is required');
  }
  // Worktree aliases are accepted: a provisioned worktree path
  // (`<repo>/.worktrees/<slug>`) resolves to its registered repository
  // (see resolveProjectDirAlias).
  final projectDir = resolveProjectDirAlias(requestedDir, config.projectDirs);
  if (projectDir == null) {
    return _text(
      'Error: project_dir must be one of: ${config.projectDirs.join(', ')}',
    );
  }
  final proj = Uri.encodeComponent(p.basename(projectDir));

  String? s(String k) => args[k] as String?;
  int? intArg(String k) {
    final v = args[k];
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  Map<String, dynamic> pick(List<String> keys) => {
    for (final k in keys)
      if (args.containsKey(k) && args[k] != null) k: args[k],
  };

  String query(Map<String, String?> params) {
    final entries = params.entries
        .where((e) => e.value != null && e.value!.isNotEmpty)
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value!)}')
        .toList();
    return entries.isEmpty ? '' : '?${entries.join('&')}';
  }

  try {
    switch (operation) {
      case 'get-project-instructions':
        final r = await client.requestJson(
          'GET',
          '/projects/$proj/instructions',
        );
        final content = (r['instructions'] as String?) ?? '';
        return _text(
          'Project dir: $projectDir\n\n'
          '${content.isEmpty ? 'No project instructions found.' : content}',
        );

      case 'add-task':
        return _inject(
          await client.requestJson(
            'POST',
            '/projects/$proj/tasks',
            body: pick(['title', 'details', 'status', 'memory']),
          ),
          projectDir,
        );

      case 'show-task':
        return _inject(
          await client.requestJson('GET', '/projects/$proj/tasks/${_id(args)}'),
          projectDir,
        );

      case 'update-task':
        return _inject(
          await client.requestJson(
            'PATCH',
            '/projects/$proj/tasks/${_id(args)}',
            body: pick(['title', 'details', 'status']),
          ),
          projectDir,
        );

      case 'show-task-memory':
        return _inject(
          await client.requestJson(
            'GET',
            '/projects/$proj/tasks/${_id(args)}/memory',
          ),
          projectDir,
        );

      case 'update-task-memory':
        return _inject(
          await client.requestJson(
            'PUT',
            '/projects/$proj/tasks/${_id(args)}/memory',
            body: {'memory': s('memory')},
          ),
          projectDir,
        );

      case 'list-tasks':
        return _inject(
          await client.requestJson(
            'GET',
            '/projects/$proj/tasks${query({'status': s('status'), 'start_at': intArg('start_at')?.toString(), 'limit': intArg('limit')?.toString()})}',
          ),
          projectDir,
        );

      case 'add-step':
        final taskId = requireArg(args, 'task_id');
        if (taskId == null) return _text('Error: task_id is required');
        return _inject(
          await client.requestJson(
            'POST',
            '/projects/$proj/tasks/$taskId/steps',
            body: pick(['title', 'details', 'sub_task_id', 'status']),
          ),
          projectDir,
        );

      case 'show-step':
        return _inject(
          await client.requestJson('GET', '/projects/$proj/steps/${_id(args)}'),
          projectDir,
        );

      case 'update-step':
        return _inject(
          await client.requestJson(
            'PATCH',
            '/projects/$proj/steps/${_id(args)}',
            body: pick(['title', 'details', 'status', 'sub_task_id']),
          ),
          projectDir,
        );

      case 'get-subtask-prompt':
        final text = await client.requestText(
          'GET',
          '/projects/$proj/steps/${_id(args)}/subtask-prompt',
        );
        return _text('Project dir: $projectDir\n\n$text');

      case 'add-item':
        return _inject(
          await client.requestJson(
            'POST',
            '/projects/$proj/items',
            body: pick(['title', 'details', 'type', 'status']),
          ),
          projectDir,
        );

      case 'show-item':
        return _inject(
          await client.requestJson('GET', '/projects/$proj/items/${_id(args)}'),
          projectDir,
        );

      case 'update-item':
        return _inject(
          await client.requestJson(
            'PATCH',
            '/projects/$proj/items/${_id(args)}',
            body: pick(['title', 'details', 'type', 'status']),
          ),
          projectDir,
        );

      case 'list-items':
        return _inject(
          await client.requestJson(
            'GET',
            '/projects/$proj/items${query({'search_query': s('search_query'), 'type': s('type'), 'status': s('status'), 'backlog_only': args['backlog_only'] == true ? 'true' : null, 'start_at': intArg('start_at')?.toString(), 'limit': intArg('limit')?.toString()})}',
          ),
          projectDir,
        );

      case 'add-slate':
        return _inject(
          await client.requestJson(
            'POST',
            '/projects/$proj/slates',
            body: pick(['title', 'notes', 'status', 'release_date']),
          ),
          projectDir,
        );

      case 'show-slate':
        return _inject(
          await client.requestJson(
            'GET',
            '/projects/$proj/slates/${_id(args)}',
          ),
          projectDir,
        );

      case 'update-slate':
        return _inject(
          await client.requestJson(
            'PATCH',
            '/projects/$proj/slates/${_id(args)}',
            body: pick(['title', 'notes', 'status', 'release_date']),
          ),
          projectDir,
        );

      case 'list-slates':
        return _inject(
          await client.requestJson(
            'GET',
            '/projects/$proj/slates${query({'status': s('status'), 'start_at': intArg('start_at')?.toString(), 'limit': intArg('limit')?.toString()})}',
          ),
          projectDir,
        );

      case 'add-item-to-slate':
        final slateId = requireArg(args, 'release_id');
        final itemId = requireArg(args, 'item_id');
        if (slateId == null || itemId == null) {
          return _text('Error: release_id and item_id are required');
        }
        return _inject(
          await client.requestJson(
            'PUT',
            '/projects/$proj/slates/$slateId/items/$itemId',
          ),
          projectDir,
        );

      case 'remove-item-from-slate':
        final slateId = requireArg(args, 'release_id');
        final itemId = requireArg(args, 'item_id');
        if (slateId == null || itemId == null) {
          return _text('Error: release_id and item_id are required');
        }
        return _inject(
          await client.requestJson(
            'DELETE',
            '/projects/$proj/slates/$slateId/items/$itemId',
          ),
          projectDir,
        );

      case 'add-item-to-task':
        final taskId = requireArg(args, 'task_id');
        final itemId = requireArg(args, 'item_id');
        if (taskId == null || itemId == null) {
          return _text('Error: task_id and item_id are required');
        }
        return _inject(
          await client.requestJson(
            'PUT',
            '/projects/$proj/tasks/$taskId/items/$itemId',
          ),
          projectDir,
        );

      case 'remove-item-from-task':
        final taskId = requireArg(args, 'task_id');
        final itemId = requireArg(args, 'item_id');
        if (taskId == null || itemId == null) {
          return _text('Error: task_id and item_id are required');
        }
        return _inject(
          await client.requestJson(
            'DELETE',
            '/projects/$proj/tasks/$taskId/items/$itemId',
          ),
          projectDir,
        );

      case 'log-commit':
        return _inject(
          await client.requestJson(
            'POST',
            '/projects/$proj/timeline/commit',
            body: pick([
              'commit_hash',
              'branch',
              'task_id',
              'step_id',
              'message',
            ]),
          ),
          projectDir,
        );

      case 'log-merge':
        return _inject(
          await client.requestJson(
            'POST',
            '/projects/$proj/timeline/merge',
            body: pick([
              'commit_hash',
              'source_branch',
              'target_branch',
              'task_id',
            ]),
          ),
          projectDir,
        );

      case 'get-timeline':
        return _inject(
          await client.requestJson(
            'GET',
            '/projects/$proj/timeline${query({'limit': intArg('limit')?.toString(), 'entity_type': s('entity_type'), 'before': s('before'), 'after': s('after')})}',
          ),
          projectDir,
        );

      case 'get-audit-trail':
        final entityType = requireArg(args, 'entity_type');
        final id = requireArg(args, 'id');
        if (entityType == null || id == null) {
          return _text('Error: entity_type and id are required');
        }
        return _inject(
          await client.requestJson(
            'GET',
            '/projects/$proj/audit/$entityType/$id${query({'limit': intArg('limit')?.toString()})}',
          ),
          projectDir,
        );

      default:
        return _text('Error: unknown operation: $operation');
    }
  } on PlannerHttpException catch (e) {
    return _text('Error: ${e.message}');
  } catch (e) {
    return _text('Error: $e');
  }
}

String _id(Map<String, dynamic> args) =>
    Uri.encodeComponent((args['id'] as String?) ?? '');

String? requireArg(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is String && v.isNotEmpty) return Uri.encodeComponent(v);
  return null;
}

/// Inject `project_dir` at the top of the JSON result, mirroring the local MCP.
CallToolResult _inject(Map<String, dynamic> data, String projectDir) =>
    _json({'project_dir': projectDir, ...data});
