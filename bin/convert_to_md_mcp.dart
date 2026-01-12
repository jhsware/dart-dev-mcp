import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:dart_dev_mcp/dart_dev_mcp.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';

/// Convert-to-MD MCP Server
///
/// Provides HTML to Markdown conversion capabilities.
///
/// Environment variables:
/// - `MCP_HTTP_TIMEOUT`: Request timeout in seconds (default: 30)
/// - `MCP_HTTP_CONNECTION_TIMEOUT`: Connection timeout in seconds (default: 10)
///
/// Usage: dart run bin/convert_to_md_mcp.dart
void main(List<String> arguments) async {
  stderr.writeln('Convert-to-MD MCP Server starting...');

  // Create HTTP client config from environment
  final httpConfig = HttpClientConfig.fromEnvironment(
    userAgent: 'Mozilla/5.0 (compatible; ConvertToMD/1.0)',
  );
  stderr.writeln('Request timeout: ${httpConfig.timeout.inSeconds}s');

  final server = McpServer(
    Implementation(name: 'convert-to-md-mcp', version: '1.0.0'),
    options: ServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // Register the convert tool
  server.tool(
    'convert-html',
    description: '''Convert HTML to Markdown or extract content.

Operations:
- convert: Convert HTML content to Markdown
- convert-url: Fetch URL and convert to Markdown
- extract-text: Extract plain text from HTML (strips all tags)
- extract-links: Extract all links from HTML as a list''',
    toolInputSchema: ToolInputSchema(
      properties: {
        'operation': {
          'type': 'string',
          'description': 'The operation to perform',
          'enum': [
            'convert',
            'convert-url',
            'extract-text',
            'extract-links',
          ],
        },
        'html': {
          'type': 'string',
          'description': 'HTML content to convert (for convert and extract-text)',
        },
        'url': {
          'type': 'string',
          'description': 'URL to fetch and convert (for convert-url and extract-links)',
        },
        'include-links': {
          'type': 'boolean',
          'description': 'Include link URLs in markdown output. Default: true',
        },
        'include-images': {
          'type': 'boolean',
          'description': 'Include images in markdown output. Default: true',
        },
      },
    ),
    callback: ({args, extra}) => _handleConvert(args, httpConfig),
  );

  final transport = StdioServerTransport();
  await server.connect(transport);
  stderr.writeln('Convert-to-MD MCP Server running on stdio');
}

Future<CallToolResult> _handleConvert(
  Map<String, dynamic>? args,
  HttpClientConfig httpConfig,
) async {
  final operation = args?['operation'] as String?;

  if (operation == null) {
    return textResult('Error: operation is required');
  }

  switch (operation) {
    case 'convert':
      final html = args?['html'] as String?;
      if (html == null || html.isEmpty) {
        return textResult('Error: html is required for convert operation');
      }
      final includeLinks = args?['include-links'] as bool? ?? true;
      final includeImages = args?['include-images'] as bool? ?? true;
      return textResult(
          _convertHtmlToMarkdown(html, includeLinks, includeImages));

    case 'convert-url':
      final url = args?['url'] as String?;
      if (url == null || url.isEmpty) {
        return textResult('Error: url is required for convert-url operation');
      }
      final includeLinks = args?['include-links'] as bool? ?? true;
      final includeImages = args?['include-images'] as bool? ?? true;
      return _convertUrl(url, includeLinks, includeImages, httpConfig);

    case 'extract-text':
      final html = args?['html'] as String?;
      if (html == null || html.isEmpty) {
        return textResult('Error: html is required for extract-text operation');
      }
      return textResult(_extractText(html));

    case 'extract-links':
      final url = args?['url'] as String?;
      final html = args?['html'] as String?;
      if (url != null && url.isNotEmpty) {
        return _extractLinksFromUrl(url, httpConfig);
      } else if (html != null && html.isNotEmpty) {
        return textResult(_extractLinks(html, null));
      }
      return textResult(
          'Error: url or html is required for extract-links operation');

    default:
      return textResult('Error: Unknown operation: $operation');
  }
}

/// Convert HTML to Markdown
String _convertHtmlToMarkdown(
    String html, bool includeLinks, bool includeImages) {
  final document = html_parser.parse(html);

  // Remove unwanted elements
  _removeElements(document,
      ['script', 'style', 'noscript', 'template', 'svg', 'canvas', 'head']);

  // Find main content
  final body = document.querySelector('body') ?? document.documentElement;
  if (body == null) {
    return '';
  }

  final buffer = StringBuffer();
  _convertNode(body, buffer, includeLinks, includeImages);

  return _cleanMarkdown(buffer.toString());
}

/// Remove specified elements from document
void _removeElements(Document document, List<String> selectors) {
  for (final selector in selectors) {
    for (final element in document.querySelectorAll(selector)) {
      element.remove();
    }
  }
}

/// Convert a DOM node to Markdown
void _convertNode(
    Node node, StringBuffer buffer, bool includeLinks, bool includeImages,
    {int listDepth = 0}) {
  if (node is Text) {
    final text = node.text.replaceAll(RegExp(r'\s+'), ' ');
    buffer.write(text);
    return;
  }

  if (node is! Element) return;

  final element = node;
  final tag = element.localName?.toLowerCase() ?? '';

  switch (tag) {
    // Headings
    case 'h1':
      buffer.write('\n\n# ');
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'h2':
      buffer.write('\n\n## ');
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'h3':
      buffer.write('\n\n### ');
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'h4':
      buffer.write('\n\n#### ');
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'h5':
      buffer.write('\n\n##### ');
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'h6':
      buffer.write('\n\n###### ');
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;

    // Paragraphs and blocks
    case 'p':
      buffer.write('\n\n');
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'div':
    case 'section':
    case 'article':
    case 'main':
    case 'header':
    case 'footer':
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      break;
    case 'br':
      buffer.write('\n');
      break;
    case 'hr':
      buffer.write('\n\n---\n\n');
      break;

    // Formatting
    case 'strong':
    case 'b':
      buffer.write('**');
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('**');
      break;
    case 'em':
    case 'i':
      buffer.write('*');
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('*');
      break;
    case 'code':
      buffer.write('`');
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('`');
      break;
    case 'pre':
      buffer.write('\n\n```\n');
      buffer.write(element.text);
      buffer.write('\n```\n\n');
      break;
    case 'blockquote':
      buffer.write('\n\n> ');
      final quoteText = _getTextContent(element);
      buffer.write(quoteText.replaceAll('\n', '\n> '));
      buffer.write('\n\n');
      break;

    // Links and images
    case 'a':
      if (includeLinks) {
        final href = element.attributes['href'] ?? '';
        final text = _getTextContent(element).trim();
        if (text.isNotEmpty && href.isNotEmpty) {
          buffer.write('[$text]($href)');
        } else if (text.isNotEmpty) {
          buffer.write(text);
        }
      } else {
        _convertChildren(element, buffer, includeLinks, includeImages,
            listDepth: listDepth);
      }
      break;
    case 'img':
      if (includeImages) {
        final src = element.attributes['src'] ?? '';
        final alt = element.attributes['alt'] ?? '';
        if (src.isNotEmpty) {
          buffer.write('![$alt]($src)');
        }
      }
      break;

    // Lists
    case 'ul':
      buffer.write('\n');
      for (final child in element.children) {
        if (child.localName == 'li') {
          buffer.write('${'  ' * listDepth}- ');
          _convertChildren(child, buffer, includeLinks, includeImages,
              listDepth: listDepth + 1);
          buffer.write('\n');
        }
      }
      buffer.write('\n');
      break;
    case 'ol':
      buffer.write('\n');
      var index = 1;
      for (final child in element.children) {
        if (child.localName == 'li') {
          buffer.write('${'  ' * listDepth}$index. ');
          _convertChildren(child, buffer, includeLinks, includeImages,
              listDepth: listDepth + 1);
          buffer.write('\n');
          index++;
        }
      }
      buffer.write('\n');
      break;

    // Tables
    case 'table':
      buffer.write('\n\n');
      _convertTable(element, buffer);
      buffer.write('\n\n');
      break;

    // Skip these
    case 'nav':
    case 'aside':
    case 'form':
    case 'button':
    case 'input':
    case 'select':
    case 'textarea':
      break;

    default:
      _convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
  }
}

void _convertChildren(
    Element element, StringBuffer buffer, bool includeLinks, bool includeImages,
    {int listDepth = 0}) {
  for (final child in element.nodes) {
    _convertNode(child, buffer, includeLinks, includeImages,
        listDepth: listDepth);
  }
}

void _convertTable(Element table, StringBuffer buffer) {
  final rows = table.querySelectorAll('tr');
  if (rows.isEmpty) return;

  // Process header row
  final headerCells = rows.first.querySelectorAll('th, td');
  if (headerCells.isNotEmpty) {
    buffer.write('| ');
    buffer.write(headerCells.map((c) => _getTextContent(c).trim()).join(' | '));
    buffer.write(' |\n');
    buffer.write('| ');
    buffer.write(headerCells.map((_) => '---').join(' | '));
    buffer.write(' |\n');
  }

  // Process data rows
  for (var i = 1; i < rows.length; i++) {
    final cells = rows[i].querySelectorAll('td, th');
    if (cells.isNotEmpty) {
      buffer.write('| ');
      buffer.write(cells.map((c) => _getTextContent(c).trim()).join(' | '));
      buffer.write(' |\n');
    }
  }
}

String _getTextContent(Element element) {
  return element.text;
}

/// Clean up the markdown output
String _cleanMarkdown(String markdown) {
  var cleaned = markdown;

  // Remove excessive blank lines (more than 2 consecutive)
  cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');

  // Remove any lingering HTML comments
  cleaned = cleaned.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  // Normalize heading spacing
  cleaned = cleaned.replaceAll(
      RegExp(r'^(#{1,6} .+)(?!\n)', multiLine: true), r'$1\n');

  // Trim whitespace
  cleaned = cleaned.trim();

  return cleaned;
}

/// Extract plain text from HTML
String _extractText(String html) {
  final document = html_parser.parse(html);

  // Remove script, style, etc.
  _removeElements(document,
      ['script', 'style', 'noscript', 'template', 'svg', 'canvas', 'head']);

  final body = document.querySelector('body') ?? document.documentElement;
  if (body == null) {
    return '';
  }

  final text = body.text;

  // Clean up whitespace
  var cleaned = text.replaceAll(RegExp(r'\s+'), ' ');

  // Decode common HTML entities
  cleaned = cleaned
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

  return cleaned.trim();
}

/// Extract links from HTML
String _extractLinks(String html, String? baseUrl) {
  final document = html_parser.parse(html);
  final links = document.querySelectorAll('a[href]');

  final result = <Map<String, String>>[];

  for (final link in links) {
    final href = link.attributes['href'] ?? '';
    if (href.isEmpty) continue;

    // Check if it's in a nav element
    var isNav = false;
    Element? parent = link.parent;
    while (parent != null) {
      if (parent.localName == 'nav' ||
          parent.localName == 'header' ||
          parent.localName == 'footer') {
        isNav = true;
        break;
      }
      parent = parent.parent;
    }

    final text = link.text.trim();

    // Resolve relative URLs if baseUrl provided
    String resolvedHref = href;
    if (baseUrl != null &&
        !href.startsWith('http://') &&
        !href.startsWith('https://')) {
      try {
        final base = Uri.parse(baseUrl);
        resolvedHref = base.resolve(href).toString();
      } catch (_) {
        // Keep original href if resolution fails
      }
    }

    result.add({
      'text': text,
      'url': resolvedHref,
      'type': isNav ? 'nav' : 'content',
    });
  }

  // Format as readable output
  final buffer = StringBuffer();
  buffer.writeln('Found ${result.length} links:\n');

  for (final link in result) {
    final navIndicator = link['type'] == 'nav' ? ' [nav]' : '';
    buffer.writeln('- ${link['text']}: ${link['url']}$navIndicator');
  }

  return buffer.toString();
}

/// Fetch URL and convert to Markdown
Future<CallToolResult> _convertUrl(
  String url,
  bool includeLinks,
  bool includeImages,
  HttpClientConfig httpConfig,
) async {
  try {
    final result = await fetchUrl(Uri.parse(url), config: httpConfig);

    if (!result.isSuccess) {
      return textResult(
          'Error: Failed to fetch URL. Status: ${result.statusCode}');
    }

    final html = result.body;
    final markdown = _convertHtmlToMarkdown(html, includeLinks, includeImages);

    return textResult('# Content from $url\n\n$markdown');
  } on HttpFetchException catch (e) {
    return textResult('Error: ${e.toUserMessage()}');
  } catch (e) {
    return textResult('Error fetching URL: $e');
  }
}

/// Extract links from URL
Future<CallToolResult> _extractLinksFromUrl(
  String url,
  HttpClientConfig httpConfig,
) async {
  try {
    final result = await fetchUrl(Uri.parse(url), config: httpConfig);

    if (!result.isSuccess) {
      return textResult(
          'Error: Failed to fetch URL. Status: ${result.statusCode}');
    }

    final html = result.body;
    return textResult(_extractLinks(html, url));
  } on HttpFetchException catch (e) {
    return textResult('Error: ${e.toUserMessage()}');
  } catch (e) {
    return textResult('Error fetching URL: $e');
  }
}
