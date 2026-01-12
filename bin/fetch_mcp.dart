import 'dart:io';

import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';

/// Default user agent for autonomous fetching
const defaultUserAgent =
    'ModelContextProtocol/1.0 (Autonomous; +https://github.com/modelcontextprotocol/servers)';

/// Fetch MCP Server
///
/// Provides URL fetching capabilities with optional robots.txt checking.
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
    options: ServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the fetch tool
  server.tool(
    'fetch',
    description:
        '''Fetches a URL from the internet and optionally extracts its contents as markdown.

Although originally you did not have internet access, this tool now grants you internet access. 
You can fetch the most up-to-date information and let the user know that.

Synonyms: fetch, follow, load, get''',
    toolInputSchema: ToolInputSchema(
      properties: {
        'url': {
          'type': 'string',
          'description': 'URL to fetch',
          'format': 'uri',
        },
        'max_length': {
          'type': 'integer',
          'description':
              'Maximum number of characters to return. Default: 5000',
          'default': 5000,
        },
        'start_index': {
          'type': 'integer',
          'description':
              'Start returning content from this character index. Useful for pagination if previous fetch was truncated. Default: 0',
          'default': 0,
        },
        'raw': {
          'type': 'boolean',
          'description':
              'Get the actual HTML content without simplification. Default: false',
          'default': false,
        },
      },
    ),
    callback: ({args, extra}) =>
        _handleFetch(args, httpConfig, ignoreRobotsTxt),
  );

  // Register the fetch_links tool
  server.tool(
    'fetch_links',
    description: '''Fetches a URL and extracts all links from it.

You can use this to recursively scrape a website to find more information.
Do not scrape too many levels deep, probably only one or two.

Synonyms: get links, find links, fetch links''',
    toolInputSchema: ToolInputSchema(
      properties: {
        'url': {
          'type': 'string',
          'description': 'URL to fetch and extract links from',
          'format': 'uri',
        },
      },
    ),
    callback: ({args, extra}) =>
        _handleFetchLinks(args, httpConfig, ignoreRobotsTxt),
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
  Map<String, dynamic>? args,
  HttpClientConfig httpConfig,
  bool ignoreRobotsTxt,
) async {
  final url = args?['url'] as String?;
  final maxLength = (args?['max_length'] as num?)?.toInt() ?? 5000;
  final startIndex = (args?['start_index'] as num?)?.toInt() ?? 0;
  final raw = args?['raw'] as bool? ?? false;

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
    final robotsResult = await _checkRobotsTxt(url, httpConfig);
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
      content = _extractContentFromHtml(pageRaw);
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
  Map<String, dynamic>? args,
  HttpClientConfig httpConfig,
  bool ignoreRobotsTxt,
) async {
  final url = args?['url'] as String?;

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
    final robotsResult = await _checkRobotsTxt(url, httpConfig);
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

    final links = _extractLinksFromHtml(pageRaw, url);
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

/// Check robots.txt for permission to fetch
/// Returns null if allowed, error message if not allowed
Future<String?> _checkRobotsTxt(String url, HttpClientConfig httpConfig) async {
  try {
    final uri = Uri.parse(url);
    final robotsTxtUrl = '${uri.scheme}://${uri.host}/robots.txt';
    final robotsTxtUri = Uri.parse(robotsTxtUrl);

    // Use single fetch for robots.txt (not critical enough to retry)
    final result = await fetchUrl(robotsTxtUri, config: httpConfig);

    if (result.statusCode == 401 || result.statusCode == 403) {
      return 'Error: When fetching robots.txt ($robotsTxtUrl), received status ${result.statusCode} so assuming autonomous fetching is not allowed';
    }

    // 4xx errors (except 401/403) mean no robots.txt, so we can proceed
    if (result.statusCode >= 400 && result.statusCode < 500) {
      return null;
    }

    if (result.statusCode != 200) {
      return null; // Can't check, proceed with caution
    }

    final robotsTxt = result.body;

    // Simple robots.txt parser
    if (!_isAllowedByRobotsTxt(robotsTxt, url, httpConfig.userAgent)) {
      return "Error: The site's robots.txt ($robotsTxtUrl) specifies that autonomous fetching is not allowed\n"
          '<useragent>${httpConfig.userAgent}</useragent>\n'
          '<url>$url</url>\n'
          '<robots>\n$robotsTxt\n</robots>';
    }

    return null;
  } on HttpFetchException catch (e) {
    // If we can't fetch robots.txt due to specific errors, provide context
    if (e.type == HttpErrorType.clientError) {
      // 4xx errors on robots.txt generally mean no robots.txt exists
      return null;
    }
    return 'Warning: Failed to fetch robots.txt: ${e.message}';
  } catch (e) {
    // If we can't fetch robots.txt, we'll proceed with caution
    return 'Warning: Failed to fetch robots.txt: $e';
  }
}

/// Simple robots.txt parser
bool _isAllowedByRobotsTxt(String robotsTxt, String url, String userAgent) {
  final uri = Uri.parse(url);
  final path = uri.path.isEmpty ? '/' : uri.path;

  final lines = robotsTxt
      .split('\n')
      .map((line) => line.trim())
      .where((line) => !line.startsWith('#') && line.isNotEmpty)
      .toList();

  String? currentUserAgent;
  bool matchesUserAgent = false;
  bool hasDisallow = false;
  bool isAllowed = true;

  for (final line in lines) {
    final colonIndex = line.indexOf(':');
    if (colonIndex == -1) continue;

    final directive = line.substring(0, colonIndex).trim().toLowerCase();
    final value = line.substring(colonIndex + 1).trim();

    if (directive == 'user-agent') {
      currentUserAgent = value.toLowerCase();
      matchesUserAgent = currentUserAgent == '*' ||
          userAgent.toLowerCase().contains(currentUserAgent);
    } else if (matchesUserAgent) {
      if (directive == 'disallow' && value.isNotEmpty) {
        hasDisallow = true;
        if (path.startsWith(value) || value == '/') {
          isAllowed = false;
        }
      } else if (directive == 'allow' && value.isNotEmpty) {
        if (path.startsWith(value)) {
          isAllowed = true;
        }
      }
    }
  }

  // If no disallow rules matched our user agent, allow
  if (!hasDisallow) {
    return true;
  }

  return isAllowed;
}

/// Extract main content from HTML as simplified text
String _extractContentFromHtml(String html) {
  try {
    final document = html_parser.parse(html);

    // Remove unwanted elements
    for (final selector in [
      'script',
      'style',
      'nav',
      'header',
      'footer',
      'iframe',
      '[role="complementary"]'
    ]) {
      for (final element in document.querySelectorAll(selector)) {
        element.remove();
      }
    }

    // Try to find main content
    final mainContent = document.querySelector('main') ??
        document.querySelector('article') ??
        document.querySelector('#content') ??
        document.querySelector('.content') ??
        document.querySelector('body');

    if (mainContent == null) {
      return '<e>Page failed to be simplified from HTML</e>';
    }

    // Clean and format the text
    final text = mainContent.text;
    return text
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\n+'), '\n')
        .trim();
  } catch (e) {
    return '<e>Failed to process HTML content: $e</e>';
  }
}

/// Extract links from HTML
List<Map<String, dynamic>> _extractLinksFromHtml(String html, String baseUrl) {
  final document = html_parser.parse(html);
  final links = <Map<String, dynamic>>[];

  for (final anchor in document.querySelectorAll('a[href]')) {
    final href = anchor.attributes['href'];
    if (href == null || href.isEmpty) continue;

    // Check if in nav
    bool navParent = false;
    Element? parent = anchor.parent;
    while (parent != null) {
      if (parent.localName == 'nav') {
        navParent = true;
        break;
      }
      parent = parent.parent;
    }

    // Resolve relative URLs
    String resolvedUrl = href;
    if (!href.startsWith('http://') && !href.startsWith('https://')) {
      try {
        final base = Uri.parse(baseUrl);
        resolvedUrl = base.resolve(href).toString();
      } catch (_) {
        // Keep original href
      }
    }

    links.add({
      'navParent': navParent,
      'url': resolvedUrl,
      'label': anchor.text.trim(),
    });
  }

  return links;
}
