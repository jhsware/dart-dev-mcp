import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Logger for retry attempts
void logConvertRetry(int attempt, int maxAttempts, HttpFetchException error,
    Duration nextDelay) {
  logWarning('convert',
      'Retry $attempt/$maxAttempts after ${error.type.name}: waiting ${nextDelay.inMilliseconds}ms');
}

const validConvertOperations = [
  'html-to-markdown',
  'fetch-to-markdown',
  'html-to-plaintext',
  'html-to-links',
];

Future<CallToolResult> handleConvert(
  Map<String, dynamic> args,
  HttpClientConfig httpConfig,
) async {
  final operation = args['operation'] as String?;

  if (requireStringOneOf(operation, 'operation', validConvertOperations) case final error?) {
    return error;
  }

  try {
    switch (operation) {
      case 'html-to-markdown':
        final html = args?['html'] as String?;
        if (requireString(html, 'html') case final error?) {
          return error;
        }
        final includeLinks = args?['include-links'] as bool? ?? true;
        final includeImages = args?['include-images'] as bool? ?? true;
        return textResult(
            convertHtmlToMarkdown(html!, includeLinks, includeImages));

      case 'fetch-to-markdown':
        final url = args?['url'] as String?;
        if (requireString(url, 'url') case final error?) {
          return error;
        }
        final includeLinks = args?['include-links'] as bool? ?? true;
        final includeImages = args?['include-images'] as bool? ?? true;
        return await convertUrl(url!, includeLinks, includeImages, httpConfig);

      case 'html-to-plaintext':
        final html = args?['html'] as String?;
        if (requireString(html, 'html') case final error?) {
          return error;
        }
        return textResult(extractText(html!));

      case 'html-to-links':
        final url = args?['url'] as String?;
        final html = args?['html'] as String?;
        if (url != null && url.isNotEmpty) {
          return await extractLinksFromUrl(url, httpConfig);
        } else if (html != null && html.isNotEmpty) {
          return textResult(extractLinks(html, null));
        }
        return validationError('url', 'url or html is required for html-to-links operation');

      default:
        return validationError('operation', 'Unknown operation: $operation');
    }
  } catch (e, stackTrace) {
    return errorResult('fetch-and-transform:$operation', e, stackTrace, {
      'operation': operation,
    });
  }
}

/// Convert HTML to Markdown
String convertHtmlToMarkdown(
    String html, bool includeLinks, bool includeImages) {
  final document = html_parser.parse(html);

  // Remove unwanted elements
  removeElements(document,
      ['script', 'style', 'noscript', 'template', 'svg', 'canvas', 'head']);

  // Find main content
  final body = document.querySelector('body') ?? document.documentElement;
  if (body == null) {
    return '';
  }

  final buffer = StringBuffer();
  convertNode(body, buffer, includeLinks, includeImages);

  return cleanMarkdown(buffer.toString());
}

/// Remove specified elements from document
void removeElements(Document document, List<String> selectors) {
  for (final selector in selectors) {
    for (final element in document.querySelectorAll(selector)) {
      element.remove();
    }
  }
}

/// Convert a DOM node to Markdown
void convertNode(
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
      convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'h2':
      buffer.write('\n\n## ');
      convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'h3':
      buffer.write('\n\n### ');
      convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'h4':
      buffer.write('\n\n#### ');
      convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'h5':
      buffer.write('\n\n##### ');
      convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'h6':
      buffer.write('\n\n###### ');
      convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;

    // Paragraphs and blocks
    case 'p':
      buffer.write('\n\n');
      convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('\n\n');
      break;
    case 'div':
    case 'section':
    case 'article':
    case 'main':
    case 'header':
    case 'footer':
      convertChildren(element, buffer, includeLinks, includeImages,
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
      convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('**');
      break;
    case 'em':
    case 'i':
      buffer.write('*');
      convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
      buffer.write('*');
      break;
    case 'code':
      buffer.write('`');
      convertChildren(element, buffer, includeLinks, includeImages,
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
      final quoteText = getTextContent(element);
      buffer.write(quoteText.replaceAll('\n', '\n> '));
      buffer.write('\n\n');
      break;

    // Links and images
    case 'a':
      if (includeLinks) {
        final href = element.attributes['href'] ?? '';
        final text = getTextContent(element).trim();
        if (text.isNotEmpty && href.isNotEmpty) {
          buffer.write('[$text]($href)');
        } else if (text.isNotEmpty) {
          buffer.write(text);
        }
      } else {
        convertChildren(element, buffer, includeLinks, includeImages,
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
          convertChildren(child, buffer, includeLinks, includeImages,
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
          convertChildren(child, buffer, includeLinks, includeImages,
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
      convertTable(element, buffer);
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
      convertChildren(element, buffer, includeLinks, includeImages,
          listDepth: listDepth);
  }
}

void convertChildren(
    Element element, StringBuffer buffer, bool includeLinks, bool includeImages,
    {int listDepth = 0}) {
  for (final child in element.nodes) {
    convertNode(child, buffer, includeLinks, includeImages,
        listDepth: listDepth);
  }
}

void convertTable(Element table, StringBuffer buffer) {
  final rows = table.querySelectorAll('tr');
  if (rows.isEmpty) return;

  // Process header row
  final headerCells = rows.first.querySelectorAll('th, td');
  if (headerCells.isNotEmpty) {
    buffer.write('| ');
    buffer.write(headerCells.map((c) => getTextContent(c).trim()).join(' | '));
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
      buffer.write(cells.map((c) => getTextContent(c).trim()).join(' | '));
      buffer.write(' |\n');
    }
  }
}

String getTextContent(Element element) {
  return element.text;
}

/// Clean up the markdown output
String cleanMarkdown(String markdown) {
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
String extractText(String html) {
  final document = html_parser.parse(html);

  // Remove script, style, etc.
  removeElements(document,
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
String extractLinks(String html, String? baseUrl) {
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
Future<CallToolResult> convertUrl(
  String url,
  bool includeLinks,
  bool includeImages,
  HttpClientConfig httpConfig,
) async {
  try {
    final result = await fetchUrlWithRetry(
      Uri.parse(url),
      config: httpConfig,
      onRetry: logConvertRetry,
    );

    if (!result.isSuccess) {
      return textResult(
          'Error: Failed to fetch URL. Status: ${result.statusCode}');
    }

    final html = result.body;
    final markdown = convertHtmlToMarkdown(html, includeLinks, includeImages);

    return textResult('# Content from $url\n\n$markdown');
  } on HttpFetchException catch (e) {
    return textResult('Error: ${e.toUserMessage()}');
  } catch (e, stackTrace) {
    return errorResult('fetch-and-transform:fetch-to-markdown', e, stackTrace, {
      'url': url,
    });
  }
}

/// Extract links from URL
Future<CallToolResult> extractLinksFromUrl(
  String url,
  HttpClientConfig httpConfig,
) async {
  try {
    final result = await fetchUrlWithRetry(
      Uri.parse(url),
      config: httpConfig,
      onRetry: logConvertRetry,
    );

    if (!result.isSuccess) {
      return textResult(
          'Error: Failed to fetch URL. Status: ${result.statusCode}');
    }

    final html = result.body;
    return textResult(extractLinks(html, url));
  } on HttpFetchException catch (e) {
    return textResult('Error: ${e.toUserMessage()}');
  } catch (e, stackTrace) {
    return errorResult('fetch-and-transform:html-to-links', e, stackTrace, {
      'url': url,
    });
  }
}
