import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';

/// Default user agent for autonomous fetching
const defaultUserAgent =
    'ModelContextProtocol/1.0 (Autonomous; +https://github.com/modelcontextprotocol/servers)';

/// Fetch MCP Server
///
/// Provides URL fetching capabilities with optional robots.txt checking.
///
/// Usage: dart run bin/fetch_mcp.dart [--ignore-robots-txt]
void main(List<String> arguments) async {
  final ignoreRobotsTxt = arguments.contains('--ignore-robots-txt');
  final customUserAgent = Platform.environment['MCP_USER_AGENT'];
  final userAgent = customUserAgent ?? defaultUserAgent;

  stderr.writeln('Fetch MCP Server starting...');
  stderr.writeln('User Agent: $userAgent');
  stderr.writeln('Ignore robots.txt: $ignoreRobotsTxt');

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
    description: '''Fetches a URL from the internet and optionally extracts its contents as markdown.

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
          'description': 'Maximum number of characters to return. Default: 5000',
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
        _handleFetch(args, userAgent, ignoreRobotsTxt),
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
        _handleFetchLinks(args, userAgent, ignoreRobotsTxt),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  stderr.writeln('Fetch MCP Server running on stdio');
}

CallToolResult _textResult(String text) {
  return CallToolResult.fromContent(
    content: [TextContent(text: text)],
  );
}

/// Handle fetch request
Future<CallToolResult> _handleFetch(
  Map<String, dynamic>? args,
  String userAgent,
  bool ignoreRobotsTxt,
) async {
  final url = args?['url'] as String?;
  final maxLength = (args?['max_length'] as num?)?.toInt() ?? 5000;
  final startIndex = (args?['start_index'] as num?)?.toInt() ?? 0;
  final raw = args?['raw'] as bool? ?? false;

  if (url == null || url.isEmpty) {
    return _textResult('Error: url is required');
  }

  // Validate URL
  Uri uri;
  try {
    uri = Uri.parse(url);
    if (!uri.hasScheme || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return _textResult('Error: Invalid URL scheme. Must be http or https.');
    }
  } catch (e) {
    return _textResult('Error: Invalid URL: $e');
  }

  // Check robots.txt
  if (!ignoreRobotsTxt) {
    final robotsResult = await _checkRobotsTxt(url, userAgent);
    if (robotsResult != null) {
      return _textResult(robotsResult);
    }
  }

  // Fetch the URL
  try {
    final response = await http.get(
      uri,
      headers: {'User-Agent': userAgent},
    );

    if (response.statusCode != 200) {
      return _textResult(
          'Error: Failed to fetch $url - status code ${response.statusCode}');
    }

    final contentType = response.headers['content-type'] ?? '';
    final pageRaw = response.body;
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
      return _textResult('<e>No more content available.</e>');
    }

    final endIndex = (startIndex + maxLength).clamp(0, originalLength);
    final truncatedContent = content.substring(startIndex, endIndex);

    if (truncatedContent.isEmpty) {
      return _textResult('<e>No more content available.</e>');
    }

    final actualContentLength = truncatedContent.length;
    final remainingContent = originalLength - (startIndex + actualContentLength);

    var finalContent = '${resultPrefix}Contents of $url:\n$truncatedContent';

    if (actualContentLength == maxLength && remainingContent > 0) {
      final nextStart = startIndex + actualContentLength;
      finalContent +=
          '\n\n<e>Content truncated. Call the fetch tool with a start_index of $nextStart to get more content.</e>';
    }

    return _textResult(finalContent);
  } catch (e) {
    return _textResult('Error fetching URL: $e');
  }
}

/// Handle fetch_links request
Future<CallToolResult> _handleFetchLinks(
  Map<String, dynamic>? args,
  String userAgent,
  bool ignoreRobotsTxt,
) async {
  final url = args?['url'] as String?;

  if (url == null || url.isEmpty) {
    return _textResult('Error: url is required');
  }

  // Validate URL
  Uri uri;
  try {
    uri = Uri.parse(url);
    if (!uri.hasScheme || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return _textResult('Error: Invalid URL scheme. Must be http or https.');
    }
  } catch (e) {
    return _textResult('Error: Invalid URL: $e');
  }

  // Check robots.txt
  if (!ignoreRobotsTxt) {
    final robotsResult = await _checkRobotsTxt(url, userAgent);
    if (robotsResult != null) {
      return _textResult(robotsResult);
    }
  }

  // Fetch the URL
  try {
    final response = await http.get(
      uri,
      headers: {'User-Agent': userAgent},
    );

    if (response.statusCode != 200) {
      return _textResult(
          'Error: Failed to fetch $url - status code ${response.statusCode}');
    }

    final contentType = response.headers['content-type'] ?? '';
    final pageRaw = response.body;
    final isHtml = pageRaw.toLowerCase().contains('<html') ||
        contentType.contains('text/html');

    if (!isHtml) {
      return _textResult(
          "Content type $contentType isn't HTML, we can't extract links.");
    }

    final links = _extractLinksFromHtml(pageRaw, url);
    final prettyLinks = links
        .map((link) =>
            '${link['label']}: ${link['url']}${link['navParent'] == true ? ' (navbar)' : ''}')
        .toList();

    return _textResult('Links of $url:\n${prettyLinks.join('\n')}');
  } catch (e) {
    return _textResult('Error fetching URL: $e');
  }
}

/// Check robots.txt for permission to fetch
/// Returns null if allowed, error message if not allowed
Future<String?> _checkRobotsTxt(String url, String userAgent) async {
  try {
    final uri = Uri.parse(url);
    final robotsTxtUrl = '${uri.scheme}://${uri.host}/robots.txt';

    final response = await http.get(
      Uri.parse(robotsTxtUrl),
      headers: {'User-Agent': userAgent},
    );

    if (response.statusCode == 401 || response.statusCode == 403) {
      return 'Error: When fetching robots.txt ($robotsTxtUrl), received status ${response.statusCode} so assuming autonomous fetching is not allowed';
    }

    // 4xx errors (except 401/403) mean no robots.txt, so we can proceed
    if (response.statusCode >= 400 && response.statusCode < 500) {
      return null;
    }

    if (response.statusCode != 200) {
      return null; // Can't check, proceed with caution
    }

    final robotsTxt = response.body;
    
    // Simple robots.txt parser
    if (!_isAllowedByRobotsTxt(robotsTxt, url, userAgent)) {
      return "Error: The site's robots.txt ($robotsTxtUrl) specifies that autonomous fetching is not allowed\n"
          '<useragent>$userAgent</useragent>\n'
          '<url>$url</url>\n'
          '<robots>\n$robotsTxt\n</robots>';
    }

    return null;
  } catch (e) {
    // If we can't fetch robots.txt, we'll proceed with caution
    return 'Warning: Failed to fetch robots.txt: $e';
  }
}

/// Simple robots.txt parser
bool _isAllowedByRobotsTxt(String robotsTxt, String url, String userAgent) {
  final uri = Uri.parse(url);
  final path = uri.path.isEmpty ? '/' : uri.path;
  
  final lines = robotsTxt.split('\n')
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
