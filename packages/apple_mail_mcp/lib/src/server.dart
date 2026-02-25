// Apple Mail MCP server setup.
//
// Registers a single `apple-mail` tool with an `operation` enum parameter
// that dispatches to the appropriate read-only operation handler.
// Long-running operations are wrapped with progress notifications and
// session tracking for polling support. Batched operations use progressive
// chunk-based output for incremental results.

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

import 'core.dart';
import 'operations/inbox.dart';
import 'operations/search.dart';
import 'operations/search_content_batched.dart';
import 'operations/search_batched.dart';
import 'operations/search_cross_account_batched.dart';
import 'operations/search_advanced_batched.dart';
import 'operations/classify_batched.dart';
import 'operations/attachments.dart';
import 'progress_wrapper.dart';
import 'session_operations.dart';

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
List<String> get allOperations => [
      ..._buildOperationHandlers().keys,
      'get_output',
      'list_sessions',
      'cancel',
    ];

/// Creates and configures the Apple Mail MCP server.
///
/// Registers a single `apple-mail` tool with all read-only operations
/// plus session management operations for long-running operation support.
McpServer createAppleMailServer() {
  final operationHandlers = _buildOperationHandlers();
  final operations = allOperations;
  final sessionManager = SessionManager();

  final server = McpServer(
    Implementation(name: 'apple-mail-mcp', version: '0.1.0'),
  );

  server.registerTool(
    'apple-mail',
    description:
        'Read-only Apple Mail operations for listing, searching, and exporting emails.\n\n'
        'For long-running operations (search-email-content, classify-emails, '
        'get-email-thread, etc.), '
        'a session_id is returned immediately. Use get_output with the session_id '
        'to poll for results. Progress notifications are sent during execution.',
    inputSchema: ToolInputSchema(
      properties: {
        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: operations,
        ),
        'account': JsonSchema.string(
          description:
              'Account name to filter by (for list-inbox-emails, get-recent-emails, list-mailboxes, search-emails, search-by-sender, search-email-content, get-newsletters, get-recent-from-sender, get-email-thread, get-statistics, export-emails, list-emails, classify-emails)',
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
        'include_counts': JsonSchema.boolean(
          description:
              'Include message counts per mailbox (for list-mailboxes). Default: true',
        ),
        'subject_keyword': JsonSchema.string(
          description:
              'Subject keyword to search for (for get-email-thread, export-emails)',
        ),
        'query': JsonSchema.string(
          description:
              'Search query — multiple space-separated keywords combined using search_operator logic (for search-emails, search-email-content)',
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
              'Maximum results to return (for search-emails, search-by-sender, search-email-content, get-newsletters, get-recent-from-sender, search-all-accounts). Default varies.',
        ),
        'max_content_length': JsonSchema.integer(
          description:
              'Maximum characters of content preview (for get-email-by-id). Default: 5000.',
        ),
        'days_back': JsonSchema.integer(
          description:
              'Number of days to look back (for search-emails, search-email-content, classify-emails, search-by-sender, get-newsletters, get-statistics, search-all-accounts). Default: 30 for search-by-sender/classify-emails, 0 (disabled) for search-emails/search-email-content.',
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
              'Name of attachment to save (for save-email-attachment, get-email-attachment). Optional for save-email-attachment — saves all if omitted.',
        ),
        'save_directory': JsonSchema.string(
          description:
              'Directory path to save files (for save-email-attachment, get-email-attachment, export-emails). Default: ~/Desktop',
        ),
        'scope': JsonSchema.string(
          description:
              'Scope for get-statistics (account_overview, sender_stats, mailbox_breakdown) or export-emails (single_email, entire_mailbox)',
        ),
        'format': JsonSchema.string(
          description:
              'Export format: txt, html (for export-emails). Default: txt',
        ),
        'limit': JsonSchema.integer(
          description:
              'Maximum number of emails to return per batch (for list-emails). Default: 20',
        ),
        'offset': JsonSchema.integer(
          description:
              'Number of emails to skip for pagination (for list-emails, search-emails, search-email-content, search-by-sender). Default: 0',
        ),
        'start_date': JsonSchema.string(
          description:
              'Start date filter in ISO format YYYY-MM-DD (for list-emails, list-inbox-emails, search-emails, search-email-content, classify-emails). For list-emails: traverses backwards from this date.',
        ),
        'end_date': JsonSchema.string(
          description:
              'End date filter in ISO format YYYY-MM-DD (for list-emails, list-inbox-emails, search-emails, search-email-content, classify-emails). Used with start_date to define a date range.',
        ),
        'fields': JsonSchema.string(
          description:
              'Comma-separated list of fields to return (for list-emails). Valid: sender, subject, date, message_id, read_status, mailbox, account, attachments. Default: "sender,subject,date,message_id"',
        ),
        'message_id': JsonSchema.string(
          description:
              'Apple Mail message ID for fetching a specific email (for get-email-by-id, save-email-attachment, list-email-attachments, get-email-attachment). Get this from list-emails or search results.',
        ),
        'search_operator': JsonSchema.string(
          description:
              'How to combine multiple keywords: "or" matches ANY keyword (default), "and" requires ALL keywords (for search-emails, search-email-content).',
        ),
        'search_field': JsonSchema.string(
          description:
              'Which fields to search: for search-emails/multi-search/classify-emails: "all" (default), "subject", "sender". For search-email-content: "all" (default), "subject", "body".',
        ),
        'queries': JsonSchema.string(
          description:
              'Comma-separated query groups for multi-search. Each group contains space-separated keywords (OR within group). Results are deduplicated and tagged with matched groups. Example: "invoice faktura, receipt kvitto, payment betalning".',
        ),
        'classifiers': JsonSchema.string(
          description:
              'JSON object mapping category names to arrays of search terms for classify-emails. The MCP uses BM25 ranking to score each email against each category. Example: {"invoice": ["invoice", "faktura", "bill"], "receipt": ["receipt", "kvitto"]}.',
        ),
        'min_score': JsonSchema.number(
          description:
              'Minimum BM25 relevance score threshold for classify-emails. Emails scoring below this for a category are excluded from that category. Default: 0.0',
        ),
        'include_unmatched': JsonSchema.boolean(
          description:
              'Whether to include emails that did not match any category in classify-emails results. Default: true',
        ),
        'session_id': JsonSchema.string(
          description:
              'Session ID returned from long-running operations (required for get_output and cancel)',
        ),
        'chunk_index': JsonSchema.integer(
          description:
              'Starting chunk index for get_output (default: 0). Use to paginate through output.',
        ),
        'max_chunks': JsonSchema.integer(
          description:
              'Maximum number of chunks to return in get_output (default: 50, max: 200)',
        ),
      },
      required: ['operation'],
    ),
    callback: (args, extra) async {
      final operation = args['operation'] as String?;
      if (operation == null) {
        return actionableError(
          'operation parameter is required.',
          'Provide one of: ${operations.join(", ")}',
        );
      }

      // Handle session management operations
      if (operation == 'get_output') {
        return handleGetOutput(args, sessionManager);
      }
      if (operation == 'list_sessions') {
        return handleListSessions(sessionManager);
      }
      if (operation == 'cancel') {
        return await handleCancelSession(args, sessionManager);
      }

      // Batched handlers need validation before dispatch since they bypass
      // the standard handler's parameter checks
      if (batchedOperations.contains(operation)) {
        BatchedHandler batchedHandler;

        if (operation == 'search-email-content') {
          final account = args['account'] as String?;
          if (account == null) {
            return actionableError(
              'account parameter is required for search-email-content.',
              'Use list-accounts to see available accounts.',
            );
          }
          final query = args['query'] as String?;
          if (query == null || query.trim().isEmpty) {
            return actionableError(
              'query parameter is required for search-email-content.',
              'Provide one or more search keywords separated by spaces.',
            );
          }
          final searchOperator = args['search_operator'] as String? ?? 'or';
          if (searchOperator != 'and' && searchOperator != 'or') {
            return actionableError(
              'Invalid search_operator "$searchOperator".',
              'Use "and" or "or".',
            );
          }
          final searchField = args['search_field'] as String? ?? 'all';
          if (!['all', 'subject', 'body'].contains(searchField)) {
            return actionableError(
              'Invalid search_field "$searchField".',
              'Use "all", "subject", or "body".',
            );
          }
          batchedHandler = runBatchedSearchEmailContent;
        } else if (operation == 'search-emails') {
          final account = args['account'] as String?;
          if (account == null) {
            return actionableError(
              'account parameter is required for search-emails.',
              'Use list-accounts to see available accounts.',
            );
          }
          final query = args['query'] as String?;
          if (query != null && query.trim().isEmpty) {
            return actionableError(
              'Empty query provided.',
              'Provide one or more search keywords separated by spaces.',
            );
          }
          final searchOperator = args['search_operator'] as String? ?? 'or';
          if (searchOperator != 'and' && searchOperator != 'or') {
            return actionableError(
              'Invalid search_operator "$searchOperator".',
              'Use "and" or "or".',
            );
          }
          final searchField = args['search_field'] as String? ?? 'all';
          if (!['all', 'subject', 'sender'].contains(searchField)) {
            return actionableError(
              'Invalid search_field "$searchField".',
              'Use "all", "subject", or "sender".',
            );
          }
          batchedHandler = runBatchedSearchEmails;
        } else if (operation == 'multi-search') {
          final account = args['account'] as String?;
          if (account == null) {
            return actionableError(
              'account parameter is required for multi-search.',
              'Use list-accounts to see available accounts.',
            );
          }
          final queries = args['queries'] as String?;
          if (queries == null || queries.trim().isEmpty) {
            return actionableError(
              'queries parameter is required for multi-search.',
              'Provide comma-separated query groups.',
            );
          }
          final searchField = args['search_field'] as String? ?? 'all';
          if (!['all', 'subject', 'sender'].contains(searchField)) {
            return actionableError(
              'Invalid search_field "$searchField".',
              'Use "all", "subject", or "sender".',
            );
          }
          batchedHandler = runBatchedMultiSearch;
        } else if (operation == 'search-by-sender') {
          final sender = args['sender'] as String?;
          if (sender == null) {
            return actionableError(
              'sender parameter is required for search-by-sender.',
              'Provide a sender name or email address to search for.',
            );
          }
          batchedHandler = runBatchedSearchBySender;
        } else if (operation == 'search-all-accounts') {
          // No required params beyond operation itself
          batchedHandler = runBatchedSearchAllAccounts;
        } else if (operation == 'get-newsletters') {
          // No required params beyond operation itself
          batchedHandler = runBatchedGetNewsletters;
        } else if (operation == 'classify-emails') {
          final account = args['account'] as String?;
          if (account == null) {
            return actionableError(
              'account parameter is required for classify-emails.',
              'Use list-accounts to see available accounts.',
            );
          }
          final classifiersJson = args['classifiers'] as String?;
          if (classifiersJson == null || classifiersJson.isEmpty) {
            return actionableError(
              'classifiers parameter is required for classify-emails.',
              'Provide a JSON object mapping category names to arrays of '
                  'search terms, e.g. {"invoice": ["invoice", "bill"]}.',
            );
          }
          // Validate JSON parses correctly
          try {
            final parsed =
                jsonDecode(classifiersJson) as Map<String, dynamic>;
            if (parsed.isEmpty) {
              return actionableError(
                'classifiers must contain at least one category.',
                'Provide at least one category with search terms.',
              );
            }
            for (final entry in parsed.entries) {
              if (entry.value is! List || (entry.value as List).isEmpty) {
                return actionableError(
                  'Category "${entry.key}" must be a non-empty list of strings.',
                  'Use format: {"category": ["term1", "term2"]}',
                );
              }
            }
          } catch (e) {
            return actionableError(
              'Invalid classifiers JSON: $e',
              'Use format: {"category": ["term1", "term2"]}',
            );
          }
          final searchField = args['search_field'] as String? ?? 'all';
          if (!['all', 'subject', 'sender'].contains(searchField)) {
            return actionableError(
              'Invalid search_field "$searchField".',
              'Use "all", "subject", or "sender".',
            );
          }
          // Validate date parameters if provided
          final dateRegex = RegExp(r'^\d{4}-\d{2}-\d{2}$');
          final startDate = args['start_date'] as String?;
          if (startDate != null && !dateRegex.hasMatch(startDate)) {
            return actionableError(
              'Invalid start_date "$startDate".',
              'Use ISO format: YYYY-MM-DD',
            );
          }
          final endDate = args['end_date'] as String?;
          if (endDate != null && !dateRegex.hasMatch(endDate)) {
            return actionableError(
              'Invalid end_date "$endDate".',
              'Use ISO format: YYYY-MM-DD',
            );
          }
          batchedHandler = runBatchedClassifyEmails;
        } else if (operation == 'get-email-thread') {
          final account = args['account'] as String?;
          if (account == null) {
            return actionableError(
              'account parameter is required for get-email-thread.',
              'Use list-accounts to see available accounts.',
            );
          }
          final subjectKeyword = args['subject_keyword'] as String?;
          if (subjectKeyword == null) {
            return actionableError(
              'subject_keyword parameter is required for get-email-thread.',
              'Provide a keyword to search for in email subject lines.',
            );
          }
          batchedHandler = runBatchedGetEmailThread;
        } else {
          return actionableError(
            'Unknown batched operation "$operation".',
            'Valid operations: ${operations.join(", ")}',
          );
        }

        return runBatchedInBackground(
          extra: extra,
          operation: operation,
          args: args,
          handler: batchedHandler,
          sessionManager: sessionManager,
        );
      }

      final handler = operationHandlers[operation];

      if (handler == null) {
        return actionableError(
          'Unknown operation "$operation".',
          'Valid operations: ${operations.join(", ")}',
        );
      }

      try {
        // Fire-and-forget: return session_id immediately, run in background
        if (slowOperations.contains(operation)) {
          return runInBackground(
            extra: extra,
            operation: operation,
            args: args,
            handler: handler,
            sessionManager: sessionManager,
          );
        }
        return await handler(args);
      } catch (e) {
        return actionableError(
          'Error executing $operation: $e',
          'If this persists, try list-accounts to verify account names, or list-mailboxes to verify mailbox names.',
        );
      }
    },
  );

  return server;
}
