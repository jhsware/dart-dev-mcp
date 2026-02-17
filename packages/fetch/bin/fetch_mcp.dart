import 'dart:io';

import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:fetch_mcp/fetch_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';


/// Default user agent for autonomous fetching
const defaultUserAgent =
    'ModelContextProtocol/1.0 (Autonomous; +https://github.com/modelcontextprotocol/servers)';

/// Fetch MCP Server
///
/// Provides URL fetching capabilities with optional robots.txt checking,
/// and HTML-to-Markdown conversion operations.
///
/// Environment variables:
/// - `MCP_USER_AGENT`: Custom user agent string
/// - `MCP_HTTP_TIMEOUT`: Request timeout in seconds (default: 30)
/// - `MCP_HTTP_CONNECTION_TIMEOUT`: Connection timeout in seconds (default: 10)
/// - `MCP_HTTP_MAX_RETRIES`: Maximum retry attempts (default: 3)
/// - `MCP_HTTP_RETRY_DELAY`: Initial retry delay in milliseconds (default: 1000)
///
/// Usage: dart run bin/fetch_mcp.dart [--ignore-robots-txt]
void main(List<String> arguments) async {
  final ignoreRobotsTxt = arguments.contains('--ignore-robots-txt');
  final customUserAgent = Platform.environment['MCP_USER_AGENT'];
  final userAgent = customUserAgent ?? defaultUserAgent;

  // Create HTTP client config from environment
  final httpConfig = HttpClientConfig.fromEnvironment(userAgent: userAgent);

  logInfo('fetch',
      'Server starting - userAgent=$userAgent timeout=${httpConfig.timeout.inSeconds}s maxRetries=${httpConfig.maxRetries} ignoreRobotsTxt=$ignoreRobotsTxt');

  final server = McpServer(
    Implementation(name: 'fetch-mcp', version: '1.0.0'),
    options: McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the fetch tool
  server.registerTool(
    'fetch',
    description:
        '''Fetches a URL from the internet and optionally extracts its contents as markdown.

Although originally you did not have internet access, this tool now grants you internet access. 
You can fetch the most up-to-date information and let the user know that.

Synonyms: fetch, follow, load, get''',
    inputSchema: ToolInputSchema(
      properties: {
        'url': JsonSchema.string(
          description: 'URL to fetch',
          format: 'uri',
        ),
        'max_length': JsonSchema.integer(
          description:
              'Maximum number of characters to return. Default: 5000',
          defaultValue: 5000,
        ),
        'start_index': JsonSchema.integer(
          description:
              'Start returning content from this character index. Useful for pagination if previous fetch was truncated. Default: 0',
          defaultValue: 0,
        ),
        'raw': JsonSchema.boolean(
          description:
              'Get the actual HTML content without simplification. Default: false',
          defaultValue: false,
        ),
      },
    ),
    callback: (args, extra) =>
        _handleFetch(args, httpConfig, ignoreRobotsTxt),
  );

  // Register the fetch_links tool
  server.registerTool(
    'fetch_links',
    description: '''Fetches a URL and extracts all links from it.

You can use this to recursively scrape a website to find more information.
Do not scrape too many levels deep, probably only one or two.

Synonyms: get links, find links, fetch links''',
    inputSchema: ToolInputSchema(
      properties: {
        'url': JsonSchema.string(
          description: 'URL to fetch and extract links from',
          format: 'uri',
        ),
      },
    ),
    callback: (args, extra) =>
        _handleFetchLinks(args, httpConfig, ignoreRobotsTxt),
  );

  // Register the fetch-and-transform tool (merged from convert_to_md_mcp)
  server.registerTool(
    'fetch-and-transform',
    description: '''Fetches a web page and extracts content for efficient research.

Operations:
- html-to-markdown: Convert HTML content to Markdown
- fetch-to-markdown: Fetch URL and convert to Markdown
- html-to-plaintext: Extract plain text from HTML (strips all tags)
- html-to-links: Extract all links from HTML as a list''',
    inputSchema: ToolInputSchema(
      properties: {
        'operation': JsonSchema.string(
          description: 'The operation to perform',
          enumValues: [
            'html-to-markdown',
            'fetch-to-markdown',
            'html-to-plaintext',
            'html-to-links',
          ],
        ),
        'html': JsonSchema.string(
          description:
              'HTML content to convert (for html-to-markdown and html-to-plaintext)',
        ),
        'url': JsonSchema.string(
          description:
              'URL to fetch and convert (for fetch-to-markdown and html-to-links)',
        ),
        'include-links': JsonSchema.boolean(
          description: 'Include link URLs in markdown output. Default: true',
        ),
        'include-images': JsonSchema.boolean(
          description: 'Include images in markdown output. Default: true',
        ),
      },
    ),
    callback: (args, extra) => handleConvert(args, httpConfig),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  logInfo('fetch', 'Server running on stdio');
}

/// Logger for retry attempts
void _logRetry(int attempt, int maxAttempts, HttpFetchException error,
    Duration nextDelay) {
  logWarning('fetch:retry',
      'Retry $attempt/$maxAttempts after ${error.type.name}: waiting ${nextDelay.inMilliseconds}ms');
}

/// Handle fetch request
Future<CallToolResult> _handleFetch(
  Map<String, dynamic> args,
  HttpClientConfig httpConfig,
  bool ignoreRobotsTxt,
) async {
  final url = args['url'] as String?;
  final maxLength = (args['max_length'] as num?)?.toInt() ?? 5000;
  final startIndex = (args['start_index'] as num?)?.toInt() ?? 0;
  final raw = args['raw'] as bool? ?? false;

  if (requireString(url, 'url') case final error?) {
    return error;
  }

  // Validate URL
  Uri uri;
  try {
    uri = Uri.parse(url!);
    if (!uri.hasScheme || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return validationError(
          'url', 'Invalid URL scheme. Must be http or https.');
    }
  } catch (e) {
    return validationError('url', 'Invalid URL: $e');
  }

  // Check robots.txt (single attempt, non-critical)
  if (!ignoreRobotsTxt) {
    final robotsResult = await checkRobotsTxt(url, httpConfig);
    if (robotsResult != null) {
      return textResult(robotsResult);
    }
  }

  // Fetch the URL with retry
  try {
    final result = await fetchUrlWithRetry(
      uri,
      config: httpConfig,
      onRetry: _logRetry,
    );

    if (!result.isSuccess) {
      return textResult(
          'Error: Failed to fetch $url - status code ${result.statusCode}');
    }

    final contentType = result.contentType;
    final pageRaw = result.body;
    final isHtml = pageRaw.toLowerCase().contains('<html') ||
        contentType.contains('text/html') ||
        contentType.isEmpty;

    String content;
    String resultPrefix = '';

    if (raw) {
      content = pageRaw;
    } else if (isHtml) {
      content = extractContentFromHtml(pageRaw);
    } else {
      content = pageRaw;
      resultPrefix =
          'Content type $contentType cannot be simplified to markdown, but here is the raw content:\n';
    }

    final originalLength = content.length;

    if (startIndex >= originalLength) {
      return textResult('<e>No more content available.</e>');
    }

    final endIndex = (startIndex + maxLength).clamp(0, originalLength);
    final truncatedContent = content.substring(startIndex, endIndex);

    if (truncatedContent.isEmpty) {
      return textResult('<e>No more content available.</e>');
    }

    final actualContentLength = truncatedContent.length;
    final remainingContent =
        originalLength - (startIndex + actualContentLength);

    var finalContent = '${resultPrefix}Contents of $url:\n$truncatedContent';

    if (actualContentLength == maxLength && remainingContent > 0) {
      final nextStart = startIndex + actualContentLength;
      finalContent +=
          '\n\n<e>Content truncated. Call the fetch tool with a start_index of $nextStart to get more content.</e>';
    }

    return textResult(finalContent);
  } on HttpFetchException catch (e) {
    return textResult('Error: ${e.toUserMessage()}');
  } catch (e, stackTrace) {
    return errorResult('fetch:fetch', e, stackTrace, {
      'url': url,
      'maxLength': maxLength,
      'startIndex': startIndex,
      'raw': raw,
    });
  }
}

/// Handle fetch_links request
Future<CallToolResult> _handleFetchLinks(
  Map<String, dynamic> args,
  HttpClientConfig httpConfig,
  bool ignoreRobotsTxt,
) async {
  final url = args['url'] as String?;

  if (requireString(url, 'url') case final error?) {
    return error;
  }

  // Validate URL
  Uri uri;
  try {
    uri = Uri.parse(url!);
    if (!uri.hasScheme || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return validationError(
          'url', 'Invalid URL scheme. Must be http or https.');
    }
  } catch (e) {
    return validationError('url', 'Invalid URL: $e');
  }

  // Check robots.txt (single attempt, non-critical)
  if (!ignoreRobotsTxt) {
    final robotsResult = await checkRobotsTxt(url, httpConfig);
    if (robotsResult != null) {
      return textResult(robotsResult);
    }
  }

  // Fetch the URL with retry
  try {
    final result = await fetchUrlWithRetry(
      uri,
      config: httpConfig,
      onRetry: _logRetry,
    );

    if (!result.isSuccess) {
      return textResult(
          'Error: Failed to fetch $url - status code ${result.statusCode}');
    }

    final contentType = result.contentType;
    final pageRaw = result.body;
    final isHtml = pageRaw.toLowerCase().contains('<html') ||
        contentType.contains('text/html');

    if (!isHtml) {
      return textResult(
          "Content type $contentType isn't HTML, we can't extract links.");
    }

    final links = extractLinksFromHtml(pageRaw, url);
    final prettyLinks = links
        .map((link) =>
            '${link['label']}: ${link['url']}${link['navParent'] == true ? ' (navbar)' : ''}')
        .toList();

    return textResult('Links of $url:\n${prettyLinks.join('\n')}');
  } on HttpFetchException catch (e) {
    return textResult('Error: ${e.toUserMessage()}');
  } catch (e, stackTrace) {
    return errorResult('fetch:fetch_links', e, stackTrace, {'url': url});
  }
}
