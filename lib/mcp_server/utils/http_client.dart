import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// Configuration for HTTP request timeouts and retry behavior.
///
/// Environment variables:
/// - `MCP_HTTP_TIMEOUT`: Overall request timeout in seconds (default: 30)
/// - `MCP_HTTP_CONNECTION_TIMEOUT`: Connection timeout in seconds (default: 10)
/// - `MCP_HTTP_MAX_RETRIES`: Maximum retry attempts (default: 3)
/// - `MCP_HTTP_RETRY_DELAY`: Initial retry delay in milliseconds (default: 1000)
class HttpClientConfig {
  /// Overall request timeout duration.
  final Duration timeout;

  /// Connection timeout duration.
  final Duration connectionTimeout;

  /// User agent string for requests.
  final String userAgent;

  /// Maximum number of retry attempts.
  final int maxRetries;

  /// Initial delay before first retry (used for exponential backoff).
  final Duration initialRetryDelay;

  /// Maximum delay between retries.
  final Duration maxRetryDelay;

  HttpClientConfig({
    Duration? timeout,
    Duration? connectionTimeout,
    String? userAgent,
    int? maxRetries,
    Duration? initialRetryDelay,
    Duration? maxRetryDelay,
  })  : timeout = timeout ?? _defaultTimeout,
        connectionTimeout = connectionTimeout ?? _defaultConnectionTimeout,
        userAgent = userAgent ?? _defaultUserAgent,
        maxRetries = maxRetries ?? _defaultMaxRetries,
        initialRetryDelay = initialRetryDelay ?? _defaultInitialRetryDelay,
        maxRetryDelay = maxRetryDelay ?? _defaultMaxRetryDelay;

  /// Creates config from environment variables.
  factory HttpClientConfig.fromEnvironment({String? userAgent}) {
    final timeoutSeconds = int.tryParse(
          Platform.environment['MCP_HTTP_TIMEOUT'] ?? '',
        ) ??
        30;
    final connectionTimeoutSeconds = int.tryParse(
          Platform.environment['MCP_HTTP_CONNECTION_TIMEOUT'] ?? '',
        ) ??
        10;
    final maxRetries = int.tryParse(
          Platform.environment['MCP_HTTP_MAX_RETRIES'] ?? '',
        ) ??
        3;
    final retryDelayMs = int.tryParse(
          Platform.environment['MCP_HTTP_RETRY_DELAY'] ?? '',
        ) ??
        1000;

    return HttpClientConfig(
      timeout: Duration(seconds: timeoutSeconds),
      connectionTimeout: Duration(seconds: connectionTimeoutSeconds),
      maxRetries: maxRetries,
      initialRetryDelay: Duration(milliseconds: retryDelayMs),
      userAgent: userAgent,
    );
  }

  static const Duration _defaultTimeout = Duration(seconds: 30);
  static const Duration _defaultConnectionTimeout = Duration(seconds: 10);
  static const int _defaultMaxRetries = 3;
  static const Duration _defaultInitialRetryDelay = Duration(seconds: 1);
  static const Duration _defaultMaxRetryDelay = Duration(seconds: 30);
  static const String _defaultUserAgent =
      'ModelContextProtocol/1.0 (Autonomous; +https://github.com/modelcontextprotocol/servers)';
}

/// Result of an HTTP fetch operation.
class HttpFetchResult {
  /// HTTP status code.
  final int statusCode;

  /// Response body.
  final String body;

  /// Response headers.
  final Map<String, String> headers;

  /// Content type from headers.
  String get contentType => headers['content-type'] ?? '';

  HttpFetchResult({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  /// Whether the request was successful (2xx status).
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Whether this is a server error (5xx status).
  bool get isServerError => statusCode >= 500 && statusCode < 600;

  /// Whether this is a client error (4xx status).
  bool get isClientError => statusCode >= 400 && statusCode < 500;

  /// Whether this was rate limited (429).
  bool get isRateLimited => statusCode == 429;

  /// Get Retry-After header value in seconds, if present.
  int? get retryAfterSeconds {
    final retryAfter = headers['retry-after'];
    if (retryAfter == null) return null;
    // Try parsing as seconds
    final seconds = int.tryParse(retryAfter);
    if (seconds != null) return seconds;
    // Try parsing as HTTP date (simplified - just return a default)
    return 60;
  }
}

/// Error types for HTTP fetch operations.
enum HttpErrorType {
  /// Request timed out.
  timeout,

  /// DNS resolution failed.
  dnsFailure,

  /// Connection refused or network unreachable.
  connectionFailed,

  /// SSL/TLS certificate error.
  sslError,

  /// Server returned error status (5xx).
  serverError,

  /// Client error (4xx).
  clientError,

  /// Rate limited (429).
  rateLimited,

  /// Unknown/general error.
  unknown,
}

/// Exception for HTTP fetch errors with detailed categorization.
class HttpFetchException implements Exception {
  /// The type of error that occurred.
  final HttpErrorType type;

  /// Human-readable error message.
  final String message;

  /// Original exception, if any.
  final Object? cause;

  /// HTTP status code, if applicable.
  final int? statusCode;

  /// Retry-After header value in seconds, if present.
  final int? retryAfterSeconds;

  /// Number of retry attempts made before this error.
  final int attemptsCount;

  HttpFetchException({
    required this.type,
    required this.message,
    this.cause,
    this.statusCode,
    this.retryAfterSeconds,
    this.attemptsCount = 1,
  });

  @override
  String toString() => message;

  /// Whether this error type is eligible for retry.
  bool get isRetryable {
    switch (type) {
      case HttpErrorType.timeout:
      case HttpErrorType.connectionFailed:
      case HttpErrorType.serverError:
      case HttpErrorType.rateLimited:
        return true;
      case HttpErrorType.dnsFailure:
      case HttpErrorType.sslError:
      case HttpErrorType.clientError:
      case HttpErrorType.unknown:
        return false;
    }
  }

  /// Creates a user-friendly error message with actionable advice.
  String toUserMessage() {
    final attemptsSuffix =
        attemptsCount > 1 ? ' (after $attemptsCount attempts)' : '';

    switch (type) {
      case HttpErrorType.timeout:
        return 'Request timed out$attemptsSuffix. The server may be slow or unresponsive. '
            'Try again later or check if the URL is correct.';
      case HttpErrorType.dnsFailure:
        return 'Could not resolve the domain name. '
            'Please check if the URL is spelled correctly.';
      case HttpErrorType.connectionFailed:
        return 'Could not connect to the server$attemptsSuffix. '
            'The server may be down or the network may be unavailable.';
      case HttpErrorType.sslError:
        return 'SSL/TLS certificate error. '
            'The site may have an invalid or expired certificate.';
      case HttpErrorType.serverError:
        return 'Server error (status $statusCode)$attemptsSuffix. '
            'The server encountered an internal error. Try again later.';
      case HttpErrorType.clientError:
        if (statusCode == 404) {
          return 'Page not found (404). '
              'The requested URL may no longer exist.';
        } else if (statusCode == 403) {
          return 'Access forbidden (403). '
              'You may not have permission to access this resource.';
        } else if (statusCode == 401) {
          return 'Authentication required (401). '
              'This resource requires login credentials.';
        }
        return 'Client error (status $statusCode). '
            'Please check if the URL is correct.';
      case HttpErrorType.rateLimited:
        final retryMsg = retryAfterSeconds != null
            ? ' Try again in $retryAfterSeconds seconds.'
            : ' Please wait before making more requests.';
        return 'Rate limited (429)$attemptsSuffix.$retryMsg';
      case HttpErrorType.unknown:
        return 'An unexpected error occurred$attemptsSuffix: $message';
    }
  }

  /// Create a copy with updated attempts count.
  HttpFetchException withAttempts(int attempts) => HttpFetchException(
        type: type,
        message: message,
        cause: cause,
        statusCode: statusCode,
        retryAfterSeconds: retryAfterSeconds,
        attemptsCount: attempts,
      );
}

/// Callback for logging retry attempts.
typedef RetryLogger = void Function(int attempt, int maxAttempts,
    HttpFetchException error, Duration nextDelay);

/// Fetches a URL with timeout support and error categorization.
///
/// Returns [HttpFetchResult] on success, throws [HttpFetchException] on error.
/// This function does NOT retry on failure. Use [fetchUrlWithRetry] for automatic retries.
Future<HttpFetchResult> fetchUrl(
  Uri uri, {
  HttpClientConfig? config,
  Map<String, String>? additionalHeaders,
}) async {
  final cfg = config ?? HttpClientConfig.fromEnvironment();

  final headers = {
    'User-Agent': cfg.userAgent,
    ...?additionalHeaders,
  };

  try {
    final response =
        await http.get(uri, headers: headers).timeout(cfg.timeout);

    final result = HttpFetchResult(
      statusCode: response.statusCode,
      body: response.body,
      headers: response.headers,
    );

    // Check for error status codes
    if (result.isRateLimited) {
      throw HttpFetchException(
        type: HttpErrorType.rateLimited,
        message: 'Rate limited (429)',
        statusCode: response.statusCode,
        retryAfterSeconds: result.retryAfterSeconds,
      );
    }

    if (result.isServerError) {
      throw HttpFetchException(
        type: HttpErrorType.serverError,
        message: 'Server error: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    if (result.isClientError) {
      throw HttpFetchException(
        type: HttpErrorType.clientError,
        message: 'Client error: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    return result;
  } on TimeoutException catch (e) {
    throw HttpFetchException(
      type: HttpErrorType.timeout,
      message: 'Request timed out after ${cfg.timeout.inSeconds} seconds',
      cause: e,
    );
  } on SocketException catch (e) {
    // Categorize socket exceptions
    final msg = e.message.toLowerCase();
    if (msg.contains('host') ||
        msg.contains('dns') ||
        msg.contains('no address')) {
      throw HttpFetchException(
        type: HttpErrorType.dnsFailure,
        message: 'DNS resolution failed: ${e.message}',
        cause: e,
      );
    }
    throw HttpFetchException(
      type: HttpErrorType.connectionFailed,
      message: 'Connection failed: ${e.message}',
      cause: e,
    );
  } on HandshakeException catch (e) {
    throw HttpFetchException(
      type: HttpErrorType.sslError,
      message: 'SSL/TLS error: ${e.message}',
      cause: e,
    );
  } on TlsException catch (e) {
    throw HttpFetchException(
      type: HttpErrorType.sslError,
      message: 'TLS error: ${e.message}',
      cause: e,
    );
  } on HttpFetchException {
    rethrow;
  } catch (e) {
    throw HttpFetchException(
      type: HttpErrorType.unknown,
      message: 'Unexpected error: $e',
      cause: e,
    );
  }
}

/// Fetches a URL with automatic retry on transient failures.
///
/// Retries on:
/// - Timeout errors
/// - Connection failures
/// - Server errors (5xx)
/// - Rate limiting (429) - respects Retry-After header
///
/// Does NOT retry on:
/// - DNS failures (likely permanent)
/// - SSL/TLS errors (security issue)
/// - Client errors (4xx except 429)
///
/// Uses exponential backoff with jitter between retries.
Future<HttpFetchResult> fetchUrlWithRetry(
  Uri uri, {
  HttpClientConfig? config,
  Map<String, String>? additionalHeaders,
  RetryLogger? onRetry,
}) async {
  final cfg = config ?? HttpClientConfig.fromEnvironment();
  HttpFetchException? lastError;

  for (var attempt = 1; attempt <= cfg.maxRetries; attempt++) {
    try {
      return await fetchUrl(
        uri,
        config: cfg,
        additionalHeaders: additionalHeaders,
      );
    } on HttpFetchException catch (e) {
      lastError = e.withAttempts(attempt);

      // Check if we should retry
      if (!e.isRetryable || attempt >= cfg.maxRetries) {
        throw lastError;
      }

      // Calculate delay with exponential backoff and jitter
      final delay = _calculateRetryDelay(
        attempt: attempt,
        initialDelay: cfg.initialRetryDelay,
        maxDelay: cfg.maxRetryDelay,
        retryAfterSeconds: e.retryAfterSeconds,
      );

      // Log the retry attempt
      onRetry?.call(attempt, cfg.maxRetries, e, delay);

      // Wait before retrying
      await Future.delayed(delay);
    }
  }

  // Should not reach here, but just in case
  throw lastError ??
      HttpFetchException(
        type: HttpErrorType.unknown,
        message: 'Failed after ${cfg.maxRetries} attempts',
        attemptsCount: cfg.maxRetries,
      );
}

/// Calculate retry delay with exponential backoff and jitter.
Duration _calculateRetryDelay({
  required int attempt,
  required Duration initialDelay,
  required Duration maxDelay,
  int? retryAfterSeconds,
}) {
  // If server specified Retry-After, respect it (with a cap)
  if (retryAfterSeconds != null) {
    final serverDelay = Duration(seconds: retryAfterSeconds);
    return serverDelay > maxDelay ? maxDelay : serverDelay;
  }

  // Exponential backoff: delay * 2^(attempt-1)
  final exponentialMs =
      initialDelay.inMilliseconds * math.pow(2, attempt - 1).toInt();

  // Add jitter (±25% randomization) to prevent thundering herd
  final random = math.Random();
  final jitterFactor = 0.75 + (random.nextDouble() * 0.5); // 0.75 to 1.25
  final delayWithJitter = (exponentialMs * jitterFactor).toInt();

  // Cap at max delay
  final cappedDelay = math.min(delayWithJitter, maxDelay.inMilliseconds);

  return Duration(milliseconds: cappedDelay);
}
