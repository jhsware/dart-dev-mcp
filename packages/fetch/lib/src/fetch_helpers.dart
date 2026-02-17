import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';
import 'package:jhsware_code_shared_libs/shared_libs.dart';

/// Check robots.txt for permission to fetch.
/// Returns null if allowed, error message if not allowed.
Future<String?> checkRobotsTxt(String url, HttpClientConfig httpConfig) async {
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
    if (!isAllowedByRobotsTxt(robotsTxt, url, httpConfig.userAgent)) {
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

/// Simple robots.txt parser.
/// Returns true if the given [url] is allowed for [userAgent].
bool isAllowedByRobotsTxt(String robotsTxt, String url, String userAgent) {
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

/// Extract main content from HTML as simplified text.
String extractContentFromHtml(String html) {
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

/// Extract links from HTML.
/// Returns a list of maps with 'url', 'label', and 'navParent' keys.
List<Map<String, dynamic>> extractLinksFromHtml(String html, String baseUrl) {
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
