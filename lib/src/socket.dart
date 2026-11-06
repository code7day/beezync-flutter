import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

abstract class BeezyncSocket {
  Stream<dynamic> get stream;
  int? get closeCode;
  void send(String data);
  Future<void> close([int? code, String? reason]);
}

typedef SocketFactory = BeezyncSocket Function(Uri uri);

BeezyncSocket defaultSocketFactory(Uri uri) => _ChannelSocket(WebSocketChannel.connect(uri));

class _ChannelSocket implements BeezyncSocket {
  _ChannelSocket(this._channel) {
    _channel.ready.then((_) {}, onError: (Object _) {});
  }

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    try {
      await _channel.sink.close(code, reason);
    } catch (_) {}
  }
}
