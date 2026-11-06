import 'dart:async';
import 'dart:convert';

import 'package:beezync_sdk/beezync_sdk.dart';

class FakeSocket implements BeezyncSocket {
  final _ctrl = StreamController<dynamic>();
  final List<Map<String, dynamic>> sent = [];
  int? _closeCode;
  bool closed = false;

  @override
  Stream<dynamic> get stream => _ctrl.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void send(String data) => sent.add(jsonDecode(data) as Map<String, dynamic>);

  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
    _closeCode = code;
  }

  void serverSend(Map<String, dynamic> frame) => _ctrl.add(jsonEncode(frame));

  void established([String id = 'sock-1']) =>
      serverSend({'event': 'connection_established', 'data': {'socket_id': id}});

  Future<void> serverClose(int? code) async {
    _closeCode = code;
    await _ctrl.close();
  }
}

class FakeSockets {
  final List<FakeSocket> created = [];
  final List<Uri> uris = [];

  FakeSocket call(Uri uri) {
    uris.add(uri);
    final s = FakeSocket();
    created.add(s);
    return s;
  }
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));
