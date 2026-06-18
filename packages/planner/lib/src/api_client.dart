import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'config.dart';

/// An HTTP-level error from planner_server, carrying the server's error code
/// and message so the MCP can surface a faithful message to the agent.
class PlannerHttpException implements Exception {
  PlannerHttpException(this.statusCode, this.code, this.message);
  final int statusCode;
  final String code;
  final String message;
  @override
  String toString() => 'PlannerHttpException($statusCode $code: $message)';
}

/// Thin HTTP client to planner_server with optional CA pinning / mTLS / bearer.
class PlannerApiClient {
  PlannerApiClient({
    required this.baseUrl,
    required http.Client client,
    this.token,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client;

  final String baseUrl;
  final String? token;
  final Duration timeout;
  final http.Client _client;

  factory PlannerApiClient.fromConfig(PlannerConfig config) {
    return PlannerApiClient(
      baseUrl: config.serverUrl,
      token: config.token,
      client: _buildClient(config),
    );
  }

  static http.Client _buildClient(PlannerConfig config) {
    final needsCustom = config.insecure ||
        config.caCertPath != null ||
        config.clientCertPath != null;
    if (!needsCustom) return http.Client();

    final ctx = SecurityContext(withTrustedRoots: true);
    if (config.caCertPath != null) {
      ctx.setTrustedCertificates(config.caCertPath!);
    }
    if (config.clientCertPath != null && config.clientKeyPath != null) {
      ctx.useCertificateChain(config.clientCertPath!);
      ctx.usePrivateKey(config.clientKeyPath!);
    }
    final httpClient = HttpClient(context: ctx);
    if (config.insecure) {
      httpClient.badCertificateCallback = (_, _, _) => true;
    }
    return IOClient(httpClient);
  }

  /// Perform a request and return the decoded JSON object body.
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final resp = await _send(method, path, body: body, accept: 'application/json');
    if (resp.body.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(resp.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'result': decoded};
  }

  /// Perform a request and return the raw body string (for text endpoints).
  Future<String> requestText(String method, String path) async {
    final resp = await _send(method, path, accept: 'text/markdown');
    return resp.body;
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String accept = 'application/json',
  }) async {
    final request = http.Request(method, Uri.parse('$baseUrl$path'));
    request.headers['accept'] = accept;
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final streamed = await _client.send(request).timeout(timeout);
    final resp = await http.Response.fromStream(streamed);

    if (resp.statusCode >= 400) {
      var code = 'HTTP_${resp.statusCode}';
      var message = resp.body.isEmpty ? 'HTTP ${resp.statusCode}' : resp.body;
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map && decoded['error'] is Map) {
          final err = decoded['error'] as Map;
          code = (err['code'] ?? code).toString();
          message = (err['message'] ?? message).toString();
        }
      } catch (_) {
        // non-JSON error body; keep raw message
      }
      throw PlannerHttpException(resp.statusCode, code, message);
    }
    return resp;
  }

  void close() => _client.close();
}
