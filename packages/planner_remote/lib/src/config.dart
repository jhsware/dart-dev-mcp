import 'dart:io';

/// Parsed configuration for the planner_remote MCP server.
///
/// CLI args (each also has an env-var fallback):
///   --project-dir=PATH        (repeatable; maps basename -> server project)
///   --server-url=URL          PLANNER_SERVER_URL
///   --token=TOKEN             PLANNER_SERVER_TOKEN
///   --ca-cert=PATH            PLANNER_SERVER_CA_CERT     (pin server CA)
///   --client-cert=PATH        PLANNER_SERVER_CLIENT_CERT (mTLS)
///   --client-key=PATH         PLANNER_SERVER_CLIENT_KEY  (mTLS)
///   --insecure                PLANNER_SERVER_INSECURE=true (skip TLS verify)
///   --help, -h
class PlannerRemoteConfig {
  PlannerRemoteConfig({
    required this.projectDirs,
    required this.serverUrl,
    required this.token,
    required this.caCertPath,
    required this.clientCertPath,
    required this.clientKeyPath,
    required this.insecure,
    required this.helpRequested,
  });

  final List<String> projectDirs;
  final String serverUrl;
  final String? token;
  final String? caCertPath;
  final String? clientCertPath;
  final String? clientKeyPath;
  final bool insecure;
  final bool helpRequested;

  static PlannerRemoteConfig parse(List<String> args) {
    final env = Platform.environment;
    final projectDirs = <String>[];
    String? serverUrl;
    String? token;
    String? caCert;
    String? clientCert;
    String? clientKey;
    var insecure = env['PLANNER_SERVER_INSECURE']?.toLowerCase() == 'true';
    var help = false;

    String? valueOf(String arg, String prefix) =>
        arg.startsWith(prefix) ? arg.substring(prefix.length) : null;

    for (final arg in args) {
      if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg == '--insecure') {
        insecure = true;
      } else if (valueOf(arg, '--project-dir=') case final v?) {
        projectDirs.add(v);
      } else if (valueOf(arg, '--server-url=') case final v?) {
        serverUrl = v;
      } else if (valueOf(arg, '--token=') case final v?) {
        token = v;
      } else if (valueOf(arg, '--ca-cert=') case final v?) {
        caCert = v;
      } else if (valueOf(arg, '--client-cert=') case final v?) {
        clientCert = v;
      } else if (valueOf(arg, '--client-key=') case final v?) {
        clientKey = v;
      }
    }

    return PlannerRemoteConfig(
      projectDirs: projectDirs,
      serverUrl:
          (serverUrl ?? env['PLANNER_SERVER_URL'] ?? 'https://localhost:9444')
              .replaceAll(RegExp(r'/+$'), ''),
      token: token ?? env['PLANNER_SERVER_TOKEN'],
      caCertPath: caCert ?? env['PLANNER_SERVER_CA_CERT'],
      clientCertPath: clientCert ?? env['PLANNER_SERVER_CLIENT_CERT'],
      clientKeyPath: clientKey ?? env['PLANNER_SERVER_CLIENT_KEY'],
      insecure: insecure,
      helpRequested: help,
    );
  }
}
