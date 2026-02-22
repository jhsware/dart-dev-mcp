// Apple Mail MCP server setup.
//
// Registers a single `apple-mail` tool with an `operation` enum parameter
// that dispatches to the appropriate read-only operation handler.

import 'package:mcp_dart/mcp_dart.dart';

import 'operations/inbox.dart';
import 'operations/search.dart';
import 'operations/attachments.dart';

/// Builds the merged dispatch map from all operation modules.
Map<String, Future<CallToolResult> Function(Map<String, dynamic>)>
    _buildOperationHandlers() {
  return {
    ...getInboxOperations(),
    ...getSearchOperations(),
    ...getAttachmentOperations(),
  };
}

/// All supported operation names for the apple-mail tool.
List<String> get allOperations => _buildOperationHandlers().keys.toList();

/// Creates and configures the Apple Mail MCP server.
///
/// Registers a single `apple-mail` tool with all 18 read-only operations.
McpServer createAppleMailServer() {
  final operationHandlers = _buildOperationHandlers();
  final operations = operationHandlers.keys.toList();

  final server = McpServer(
    Implementation(name: 'apple-mail-mcp', version: '0.1.0'),
  );

  server.registerTool(
    'apple-mail',
    description:
        'Read-only Apple Mail operations for listing, searching, and exporting emails.',
    inputSchema: ToolInputSchema(
      properties: {
        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: operations,
        ),
        'account': JsonSchema.string(
          description:
              'Account name to filter by (for list-inbox-emails, get-recent-emails, list-mailboxes, search-emails, search-by-sender, search-email-content, get-newsletters, get-recent-from-sender, get-email-thread, get-statistics, export-emails)',
        ),
        'max_emails': JsonSchema.integer(
          description:
              'Maximum number of emails to return (for list-inbox-emails). 0 = unlimited.',
        ),
        'include_read': JsonSchema.boolean(
          description:
              'Include read emails (for list-inbox-emails). Default: true',
        ),
        'count': JsonSchema.integer(
          description:
              'Number of emails to return (for get-recent-emails, get-recent-from-sender). Default: 10',
        ),
        'include_content': JsonSchema.boolean(
          description:
              'Include email content preview (for get-recent-emails, get-recent-from-sender). Default: false',
        ),
        'include_counts': JsonSchema.boolean(
          description:
              'Include message counts per mailbox (for list-mailboxes). Default: true',
        ),
        'subject_keyword': JsonSchema.string(
          description:
              'Subject keyword to search for (for get-email-with-content, get-email-thread, save-email-attachment, list-email-attachments, export-emails)',
        ),
        'query': JsonSchema.string(
          description:
              'Search query (for search-emails, search-email-content)',
        ),
        'sender': JsonSchema.string(
          description:
              'Sender email/name to search for (for search-by-sender, get-recent-from-sender, get-statistics)',
        ),
        'search_body': JsonSchema.boolean(
          description:
              'Also search email body (for search-email-content). Default: true',
        ),
        'time_range': JsonSchema.string(
          description:
              'Time range filter: today, yesterday, week, month, quarter, year, all (for get-recent-from-sender)',
        ),
        'max_results': JsonSchema.integer(
          description:
              'Maximum results to return (for search-emails, search-by-sender, search-email-content, get-newsletters, get-recent-from-sender, search-all-accounts, list-email-attachments). Default varies.',
        ),
        'max_content_length': JsonSchema.integer(
          description:
              'Maximum characters of content preview (for get-email-with-content, search-by-sender, search-email-content, get-newsletters, get-recent-from-sender, search-all-accounts). Default varies.',
        ),
        'days_back': JsonSchema.integer(
          description:
              'Number of days to look back (for search-by-sender, get-newsletters, get-statistics, search-all-accounts). Default: 30',
        ),
        'has_attachments': JsonSchema.boolean(
          description:
              'Filter by attachment presence (for search-emails). null = no filter.',
        ),
        'read_status': JsonSchema.string(
          description:
              'Filter by read status: all, read, unread (for search-emails). Default: all',
        ),
        'mailbox': JsonSchema.string(
          description:
              'Mailbox name (for various operations). Default: INBOX. Use "All" for cross-mailbox search.',
        ),
        'attachment_name': JsonSchema.string(
          description:
              'Name of attachment to save (for save-email-attachment). Optional — saves all if omitted.',
        ),
        'save_directory': JsonSchema.string(
          description:
              'Directory path to save files (for save-email-attachment, export-emails). Default: ~/Desktop',
        ),
        'scope': JsonSchema.string(
          description:
              'Scope for get-statistics (account_overview, sender_stats, mailbox_breakdown) or export-emails (single_email, entire_mailbox)',
        ),
        'format': JsonSchema.string(
          description:
              'Export format: txt, html (for export-emails). Default: txt',
        ),
      },
      required: ['operation'],
    ),
    callback: (args, extra) async {
      final operation = args['operation'] as String?;
      if (operation == null) {
        return CallToolResult.fromContent(
          [TextContent(text: 'Error: operation parameter is required')],
        );
      }

      final handler = operationHandlers[operation];
      if (handler == null) {
        return CallToolResult.fromContent([
          TextContent(
            text:
                'Error: Unknown operation "$operation". Valid operations: ${operations.join(", ")}',
          ),
        ]);
      }

      try {
        return await handler(args);
      } catch (e) {
        return CallToolResult.fromContent(
          [TextContent(text: 'Error executing $operation: $e')],
        );
      }
    },
  );

  return server;
}
