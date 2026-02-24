/// Read-only Apple Mail MCP server for Dart.
///
/// Provides a single `apple-mail` tool with read-only operations
/// for listing, searching, and exporting emails from Apple Mail.
library;

export 'src/server.dart' show createAppleMailServer, allOperations;
export 'src/operations/inbox.dart' show getInboxOperations;
export 'src/operations/search.dart' show getSearchOperations;
export 'src/operations/search_content_batched.dart'
    show runBatchedSearchEmailContent;
export 'src/operations/search_batched.dart'
    show runBatchedSearchEmails, runBatchedMultiSearch;
export 'src/operations/search_cross_account_batched.dart'
    show
        runBatchedSearchBySender,
        runBatchedSearchAllAccounts,
        runBatchedGetNewsletters;
export 'src/operations/classify_batched.dart'
    show runBatchedClassifyEmails;
export 'src/operations/attachments.dart' show getAttachmentOperations;
export 'src/batch_helpers.dart'
    show batchList, fetchMessageIds, buildMessageIdSet, fetchAccountNames;
export 'src/progress_wrapper.dart'
    show
        slowOperations,
        batchedOperations,
        runInBackground,
        runBatchedInBackground,
        BatchedHandler;
export 'src/core.dart'
    show
        runAppleScript,
        escapeAppleScript,
        parseEmailList,
        buildJsonEmailOutput,
        actionableError,
        safeDateScript;

export 'src/session_operations.dart'
    show handleGetOutput, handleListSessions, handleCancelSession;
export 'src/constants.dart';
