import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'fcm.dart';
import 'message.dart';
import 'socket.dart';

typedef BackoffFn = Duration Function(int attempt);

class Beezync {
  Beezync(
    this.config, {
    http.Client? httpClient,
    SocketFactory? socketFactory,
    Random? random,
    BackoffFn? backoff,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _socketFactory = socketFactory ?? defaultSocketFactory,
        _random = random ?? Random() {
    _backoff = backoff ?? _defaultBackoff;
  }

  final BeezyncConfig config;
  final http.Client _http;
  final bool _ownsHttp;
  final SocketFactory _socketFactory;
  final Random _random;
  late final BackoffFn _backoff;

  final _messages = StreamController<BeezyncMessage>.broadcast();
  final _states = StreamController<BeezyncConnectionState>.broadcast();
  final _subEvents = StreamController<SubscriptionEvent>.broadcast();

  final Map<String, Map<String, String>> _subscriptions = {};
  BeezyncConnectionState _state = BeezyncConnectionState.disconnected;
  BeezyncSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  bool _manualClose = true;
  int _attempt = 0;
  String? _socketId;
  String? _token;
  String? _externalUserId;

  Stream<BeezyncMessage> get messages => _messages.stream;
  Stream<BeezyncConnectionState> get connectionState => _states.stream;
  Stream<SubscriptionEvent> get subscriptionEvents => _subEvents.stream;
  BeezyncConnectionState get state => _state;
  String? get socketId => _socketId;
  String? get deviceToken => _token;
  set deviceToken(String? value) => _token = value;

  StreamSubscription<BeezyncMessage> onMessage(void Function(BeezyncMessage) handler) =>
      messages.listen(handler);

  Duration debugBackoff(int attempt) => _backoff(attempt);

  Duration _defaultBackoff(int attempt) {
    final capped = min(30000, 1000 * (1 << min(attempt, 10)));
    final jittered = (capped * (0.8 + 0.4 * _random.nextDouble())).round();
    return Duration(milliseconds: jittered.clamp(1000, 30000));
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${config.publicKey}',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  Future<BeezyncResult> _request(String method, String path, Map<String, dynamic> body) async {
    try {
      final req = http.Request(method, config.apiUri(path))
        ..headers.addAll(_headers)
        ..body = jsonEncode(body);
      final streamed = await _http.send(req).timeout(config.requestTimeout);
      final res = await http.Response.fromStream(streamed).timeout(config.requestTimeout);
      Map<String, dynamic>? parsed;
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) parsed = decoded;
      } catch (_) {}
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      return BeezyncResult(
        ok: ok,
        statusCode: res.statusCode,
        error: ok ? null : (parsed?['error']?.toString() ?? 'http_${res.statusCode}'),
        body: parsed,
      );
    } on TimeoutException {
      return const BeezyncResult(ok: false, error: 'timeout');
    } catch (e) {
      return BeezyncResult(ok: false, error: 'network: ${e.runtimeType}');
    }
  }

  Future<BeezyncResult> registerDevice({
    required String token,
    required String platform,
    String? externalUserId,
    Map<String, dynamic>? tags,
  }) async {
    final res = await _request('POST', '/v1/api/register-device', {
      'token': token,
      'platform': platform,
      if (externalUserId != null) 'external_user_id': externalUserId,
      if (tags != null) 'tags': tags,
      if (tags != null) 'metadata': tags,
    });
    if (res.ok) {
      _token = token;
      _externalUserId = externalUserId ?? _externalUserId;
    }
    return res;
  }

  Future<BeezyncResult> unregisterDevice([String? token]) async {
    final t = token ?? _token;
    if (t == null) return const BeezyncResult(ok: false, error: 'no_token');
    final res = await _request('POST', '/v1/api/unregister-device', {'token': t});
    if (res.ok && t == _token) _token = null;
    return res;
  }

  Future<BeezyncResult> setUser(String externalUserId, {String? token}) async {
    final t = token ?? _token;
    if (t == null) return const BeezyncResult(ok: false, error: 'no_token');
    final res = await _request('PATCH', '/v1/api/devices', {
      'token': t,
      'external_user_id': externalUserId,
    });
    if (res.ok) _externalUserId = externalUserId;
    return res;
  }

  Future<BeezyncResult> setTags(Map<String, dynamic> tags, {String? token}) async {
    final t = token ?? _token;
    if (t == null) return const BeezyncResult(ok: false, error: 'no_token');
    return _request('PATCH', '/v1/api/devices', {'token': t, 'tags': tags});
  }

  String? get externalUserId => _externalUserId;

  Future<BeezyncResult> _track(String id, String event) {
    return _request('POST', '/v1/api/notification-events', {
      'notification_id': id,
      'event': event,
      if (_token != null) 'token': _token,
    });
  }

  Future<BeezyncResult> trackReceived(String id) => _track(id, 'received');
  Future<BeezyncResult> trackClicked(String id) => _track(id, 'clicked');
  Future<BeezyncResult> trackDismissed(String id) => _track(id, 'dismissed');

  Future<BeezyncResult> trackReceivedFromData(Map<String, dynamic>? data) =>
      _trackFromData(data, trackReceived);
  Future<BeezyncResult> trackClickedFromData(Map<String, dynamic>? data) =>
      _trackFromData(data, trackClicked);
  Future<BeezyncResult> trackDismissedFromData(Map<String, dynamic>? data) =>
      _trackFromData(data, trackDismissed);

  Future<BeezyncResult> _trackFromData(
    Map<String, dynamic>? data,
    Future<BeezyncResult> Function(String) fn,
  ) {
    final id = bzIdFromData(data);
    if (id == null) return Future.value(const BeezyncResult(ok: false, error: 'no_bz_id'));
    return fn(id);
  }

  void connect() {
    if (_socket != null) return;
    _manualClose = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _open();
  }

  Future<void> disconnect() async {
    _manualClose = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    final sock = _socket;
    final sub = _socketSub;
    _socket = null;
    _socketSub = null;
    _socketId = null;
    _setState(BeezyncConnectionState.disconnected);
    await sub?.cancel();
    await sock?.close(1000);
  }

  Future<void> dispose() async {
    await disconnect();
    await _messages.close();
    await _states.close();
    await _subEvents.close();
    if (_ownsHttp) _http.close();
  }

  void subscribe(String channel, {String? auth, String? token}) {
    _subscriptions[channel] = {
      if (auth != null) 'auth': auth,
      if (token != null) 'token': token,
    };
    if (_state == BeezyncConnectionState.connected) _sendSubscribe(channel);
  }

  void unsubscribe(String channel) {
    _subscriptions.remove(channel);
    if (_state == BeezyncConnectionState.connected) {
      _send({'action': 'unsubscribe', 'channel': channel});
    }
  }

  List<String> get channels => List.unmodifiable(_subscriptions.keys);

  void _sendSubscribe(String channel) {
    final extra = _subscriptions[channel] ?? const {};
    _send({'action': 'subscribe', 'channel': channel, ...extra});
  }

  void _send(Map<String, dynamic> frame) {
    try {
      _socket?.send(jsonEncode(frame));
    } catch (_) {}
  }

  void _setState(BeezyncConnectionState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  void _open() {
    _setState(BeezyncConnectionState.connecting);
    final BeezyncSocket sock;
    try {
      sock = _socketFactory(config.wsUri);
    } catch (_) {
      _setState(BeezyncConnectionState.disconnected);
      _scheduleReconnect(null);
      return;
    }
    _socket = sock;
    _socketSub = sock.stream.listen(
      (raw) => _onFrame(sock, raw),
      onError: (Object _) {},
      onDone: () => _onClosed(sock),
      cancelOnError: false,
    );
  }

  void _onFrame(BeezyncSocket sock, dynamic raw) {
    if (!identical(sock, _socket)) return;
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
      if (decoded is! Map<String, dynamic>) return;
      json = decoded;
    } catch (_) {
      return;
    }
    switch (json['event']) {
      case 'connection_established':
        final data = json['data'];
        if (data is Map) _socketId = data['socket_id']?.toString();
        if (data is String) {
          try {
            final inner = jsonDecode(data);
            if (inner is Map) _socketId = inner['socket_id']?.toString();
          } catch (_) {}
        }
        _attempt = 0;
        _setState(BeezyncConnectionState.connected);
        _startPing();
        for (final c in _subscriptions.keys.toList()) {
          _sendSubscribe(c);
        }
        return;
      case 'subscription_succeeded':
        if (!_subEvents.isClosed) {
          _subEvents.add(SubscriptionEvent(json['channel']?.toString() ?? ''));
        }
        return;
      case 'subscription_error':
        if (!_subEvents.isClosed) {
          _subEvents.add(SubscriptionEvent(
            json['channel']?.toString() ?? '',
            error: json['error']?.toString() ?? 'subscription_error',
          ));
        }
        return;
      case 'pong':
        return;
    }
    if (!_messages.isClosed) _messages.add(BeezyncMessage.fromJson(json));
  }

  void _onClosed(BeezyncSocket sock) {
    if (!identical(sock, _socket)) return;
    final code = sock.closeCode;
    _socket = null;
    _socketSub = null;
    _socketId = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _setState(BeezyncConnectionState.disconnected);
    if (_manualClose) return;
    _scheduleReconnect(code);
  }

  void _scheduleReconnect(int? code) {
    _reconnectTimer?.cancel();
    final Duration delay;
    if (code == 4200) {
      _attempt = 0;
      delay = Duration.zero;
    } else {
      delay = _backoff(_attempt);
      _attempt++;
    }
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_manualClose || _socket != null) return;
      _open();
    });
  }

  void _startPing() {
    _pingTimer?.cancel();
    final every = config.pingInterval;
    if (every == null) return;
    _pingTimer = Timer.periodic(every, (_) => _send({'action': 'ping'}));
  }
}
