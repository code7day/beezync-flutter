@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beezync_sdk/beezync_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

final env = Platform.environment;
final enabled = env['BEEZYNC_INTEGRATION'] == '1';

Future<Map<String, dynamic>> secretCall(
  String method,
  String path, [
  Map<String, dynamic>? body,
]) async {
  final req = http.Request(method, Uri.parse('${env['BASE_URL']}$path'))
    ..headers['Authorization'] = 'Bearer ${env['SECRET_KEY']}'
    ..headers['Content-Type'] = 'application/json';
  if (body != null) req.body = jsonEncode(body);
  final res = await http.Response.fromStream(await req.send());
  expect(res.statusCode, inInclusiveRange(200, 299), reason: '$path ${res.body}');
  return jsonDecode(res.body) as Map<String, dynamic>;
}

Future<BeezyncMessage> nextWhere(
  Stream<BeezyncMessage> s,
  bool Function(BeezyncMessage) test,
) =>
    s.firstWhere(test).timeout(const Duration(seconds: 10));

void main() {
  test(
    'end to end against a running engine',
    () async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final user = 'sdk-it-$stamp';
      final token = 'fake-fcm-token-$stamp';
      final channel = 'sdk-it-$stamp';

      final bz = Beezync(BeezyncConfig(
        appId: env['APP_ID']!,
        publicKey: env['PUBLIC_KEY']!,
        baseUrl: env['BASE_URL']!,
      ));
      addTearDown(bz.dispose);

      final reg = await bz.registerDevice(
        token: token,
        platform: 'android',
        externalUserId: user,
        tags: {'suite': 'integration'},
      );
      expect(reg.ok, isTrue, reason: reg.toString());
      expect((await bz.setTags({'extra': 'yes'})).ok, isTrue);
      expect((await bz.setUser(user)).ok, isTrue);

      final connected = bz.connectionState
          .firstWhere((s) => s == BeezyncConnectionState.connected)
          .timeout(const Duration(seconds: 10));
      final subscribed = bz.subscriptionEvents
          .firstWhere((e) => e.channel == channel)
          .timeout(const Duration(seconds: 10));
      bz.subscribe(channel);
      bz.connect();
      await connected;
      expect(bz.socketId, isNotNull);
      expect((await subscribed).ok, isTrue);

      final published = nextWhere(bz.messages, (m) => m.event == 'it.event');
      await secretCall('POST', '/v1/api/publish', {
        'channel': channel,
        'event': 'it.event',
        'data': {'n': 1},
      });
      final pub = await published;
      expect(pub.channel, channel);
      expect(pub.data, {'n': 1});

      final pushed = nextWhere(bz.messages, (m) => m.isNotification && m.title == 'sdk-it');
      final sent = await secretCall('POST', '/v1/api/send-push', {
        'title': 'sdk-it',
        'body': 'hello $stamp',
        'target_type': 'channel',
        'target_value': channel,
        'transport': 'ws',
      });
      final notificationId = sent['id'] as String;
      final note = await pushed;
      expect(note.body, 'hello $stamp');
      expect(note.id, notificationId);

      expect((await bz.trackReceived(note.id!)).ok, isTrue);
      expect((await bz.trackReceived(note.id!)).ok, isTrue);
      expect((await bz.trackClicked(note.id!)).ok, isTrue);

      Map<String, dynamic>? stats;
      for (var i = 0; i < 10; i++) {
        stats = await secretCall('GET', '/v1/api/notifications/$notificationId');
        if (stats['received'] == 1 && stats['clicked'] == 1) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(stats!['received'], 1);
      expect(stats['clicked'], 1);
      expect(stats['dismissed'], 0);

      await bz.disconnect();
      expect((await bz.unregisterDevice()).ok, isTrue);
    },
    skip: enabled ? false : 'set BEEZYNC_INTEGRATION=1 plus BASE_URL, APP_ID, PUBLIC_KEY, SECRET_KEY',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
