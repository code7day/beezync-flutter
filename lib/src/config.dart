class BeezyncConfig {
  const BeezyncConfig({
    required this.appId,
    required this.publicKey,
    required this.baseUrl,
    this.requestTimeout = const Duration(seconds: 15),
    this.pingInterval = const Duration(seconds: 25),
  });

  final String appId;
  final String publicKey;
  final String baseUrl;
  final Duration requestTimeout;
  final Duration? pingInterval;

  Uri apiUri(String path) => _base().replace(path: '${_base().path}$path');

  Uri get wsUri {
    final base = _base();
    final secure = base.scheme == 'https' || base.scheme == 'wss';
    return base.replace(
      scheme: secure ? 'wss' : 'ws',
      path: '${base.path}/v1/ws',
      queryParameters: {'app_id': appId, 'key': publicKey},
    );
  }

  Uri _base() {
    final u = Uri.parse(baseUrl);
    final p = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
    return u.replace(path: p);
  }
}
