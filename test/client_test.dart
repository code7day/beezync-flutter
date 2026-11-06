import 'dart:convert';

import 'package:beezync_sdk/beezync_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const config = BeezyncConfig(
  appId: 'app-1',
  publicKey: 'pk_test',
  baseUrl: 'http://localhost:8099/',
  pingInterval: null,
);

void main() {
  group('config', () {
    test('builds ws uri', () {
      expect(config.wsUri.toString(), 'ws://localhost:8099/v1/ws?app_id=app-1&key=pk_test');
      const secure = BeezyncConfig(appId: 'a', publicKey: 'k', baseUrl: 'https://api.beezync.com');
      expect(secure.wsUri.scheme, 'wss');
      expect(secure.apiUri('/v1/api/x').toString(), 'https://api.beezync.com/v1/api/x');
    });
  });

  group('http', () {
    late List<http.Request> requests;
    late Beezync bz;

    setUp(() {
      requests = [];
      final mock = MockClient((req) async {
        requests.add(req);
        if (req.url.path.endsWith('/boom')) return http.Response('x', 500);
        return http.Response('{"status":"ok"}', 200);
      });
      bz = Beezync(config, httpClient: mock);
    });

    test('registerDevice sends auth and body', () async {
      final r = await bz.registerDevice(
        token: 'tok',
        platform: 'android',
        externalUserId: 'u1',
        tags: {'plan': 'pro'},
      );
      expect(r.ok, isTrue);
      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/v1/api/register-device');
      expect(req.headers['Authorization'], 'Bearer pk_test');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['token'], 'tok');
      expect(body['platform'], 'android');
      expect(body['external_user_id'], 'u1');
      expect(body['tags'], {'plan': 'pro'});
      expect(bz.deviceToken, 'tok');
    });

    test('setUser, setTags and track use stored token', () async {
      expect((await bz.setUser('u')).error, 'no_token');
      await bz.registerDevice(token: 'tok', platform: 'ios');
      await bz.setUser('u2');
      await bz.setTags({'a': 1});
      await bz.trackReceived('n1');
      await bz.trackClicked('n1');
      await bz.trackDismissed('n1');
      expect(requests[1].method, 'PATCH');
      expect(jsonDecode(requests[1].body), {'token': 'tok', 'external_user_id': 'u2'});
      expect(jsonDecode(requests[2].body), {'token': 'tok', 'tags': {'a': 1}});
      final events = requests.skip(3).map((r) => jsonDecode(r.body)['event']).toList();
      expect(events, ['received', 'clicked', 'dismissed']);
      expect(requests[3].url.path, '/v1/api/notification-events');
      expect(jsonDecode(requests[3].body)['notification_id'], 'n1');
    });

    test('unregisterDevice clears token', () async {
      await bz.registerDevice(token: 'tok', platform: 'ios');
      final r = await bz.unregisterDevice();
      expect(r.ok, isTrue);
      expect(bz.deviceToken, isNull);
    });

    test('errors are returned, not thrown', () async {
      final failing = Beezync(config, httpClient: MockClient((_) async => throw Exception('down')));
      final r = await failing.registerDevice(token: 't', platform: 'android');
      expect(r.ok, isFalse);
      expect(r.error, startsWith('network'));
      final bad = Beezync(
        config,
        httpClient: MockClient((_) async => http.Response('{"error":"nope"}', 401)),
      );
      final r2 = await bad.trackReceived('x');
      expect(r2.statusCode, 401);
      expect(r2.error, 'nope');
    });

    test('track from fcm data', () async {
      expect((await bz.trackReceivedFromData({'a': 'b'})).error, 'no_bz_id');
      await bz.trackClickedFromData({'bz_id': 'abc'});
      expect(jsonDecode(requests.single.body)['notification_id'], 'abc');
    });
  });

  test('bzIdFromData', () {
    expect(bzIdFromData({'bz_id': 'x'}), 'x');
    expect(bzIdFromData({'bz_id': ''}), isNull);
    expect(bzIdFromData(null), isNull);
    expect(bzIdFromData({'other': 1}), isNull);
  });

  group('websocket', () {
    late FakeSockets sockets;
    late List<Duration> delays;
    late Beezync bz;

    setUp(() {
      sockets = FakeSockets();
      delays = [];
      bz = Beezync(
        config,
        socketFactory: sockets.call,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        backoff: (attempt) {
          delays.add(Duration(milliseconds: 10 * (attempt + 1)));
          return delays.last;
        },
      );
    });

    tearDown(() => bz.dispose());

    test('connect, subscribe, receive messages and notifications', () async {
      final got = <BeezyncMessage>[];
      bz.onMessage(got.add);
      bz.connect();
      bz.subscribe('news');
      await pump();
      final s = sockets.created.single;
      expect(sockets.uris.single.queryParameters, {'app_id': 'app-1', 'key': 'pk_test'});
      expect(s.sent, isEmpty);
      s.established('abc');
      await pump();
      expect(bz.state, BeezyncConnectionState.connected);
      expect(bz.socketId, 'abc');
      expect(s.sent, [
        {'action': 'subscribe', 'channel': 'news'}
      ]);
      s.serverSend({'event': 'subscription_succeeded', 'channel': 'news'});
      s.serverSend({'event': 'pong'});
      s.serverSend({'event': 'ev', 'channel': 'news', 'data': {'k': 1}, 'id': 'm1', 'ts': '2026-01-01T00:00:00Z'});
      s.serverSend({'id': 'n1', 'title': 'T', 'body': 'B', 'data': {'x': 'y'}});
      await pump();
      expect(got, hasLength(2));
      expect(got[0].event, 'ev');
      expect(got[0].data, {'k': 1});
      expect(got[0].ts, isNotNull);
      expect(got[0].isNotification, isFalse);
      expect(got[1].isNotification, isTrue);
      expect(got[1].title, 'T');
    });

    test('private subscribe carries auth and unsubscribe sends frame', () async {
      bz.connect();
      await pump();
      final s = sockets.created.single..established();
      await pump();
      bz.subscribe('private-x', auth: 'deadbeef');
      bz.subscribe('private-y', token: 'tk');
      bz.unsubscribe('private-x');
      expect(s.sent, [
        {'action': 'subscribe', 'channel': 'private-x', 'auth': 'deadbeef'},
        {'action': 'subscribe', 'channel': 'private-y', 'token': 'tk'},
        {'action': 'unsubscribe', 'channel': 'private-x'},
      ]);
      expect(bz.channels, ['private-y']);
    });

    test('subscription_error is surfaced', () async {
      final evs = <SubscriptionEvent>[];
      bz.subscriptionEvents.listen(evs.add);
      bz.connect();
      await pump();
      sockets.created.single
        ..established()
        ..serverSend({'event': 'subscription_error', 'channel': 'private-z', 'error': 'denied'});
      await pump();
      expect(evs.single.ok, isFalse);
      expect(evs.single.error, 'denied');
    });

    test('reconnects with backoff and resubscribes', () async {
      bz.subscribe('a');
      bz.subscribe('b');
      bz.connect();
      await pump();
      final s1 = sockets.created.single..established();
      await pump();
      await s1.serverClose(1006);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sockets.created, hasLength(2));
      expect(delays, [const Duration(milliseconds: 10)]);
      final s2 = sockets.created[1]..established('two');
      await pump();
      expect(s2.sent.map((f) => f['channel']), ['a', 'b']);
      expect(bz.socketId, 'two');
    });

    test('backoff attempts grow while failing and reset after success', () async {
      bz.connect();
      await pump();
      await sockets.created[0].serverClose(1006);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await sockets.created[1].serverClose(1006);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(delays.take(2), [const Duration(milliseconds: 10), const Duration(milliseconds: 20)]);
      sockets.created[2].established();
      await pump();
      await sockets.created[2].serverClose(1006);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(delays[2], const Duration(milliseconds: 10));
    });

    test('close code 4200 reconnects immediately without backoff', () async {
      bz.connect();
      await pump();
      await sockets.created.single.serverClose(4200);
      await pump();
      expect(sockets.created, hasLength(2));
      expect(delays, isEmpty);
    });

    test('disconnect stops reconnecting', () async {
      bz.connect();
      await pump();
      sockets.created.single.established();
      await pump();
      await bz.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sockets.created, hasLength(1));
      expect(sockets.created.single.closed, isTrue);
      expect(bz.state, BeezyncConnectionState.disconnected);
    });

    test('default backoff stays within 1s..30s', () {
      final real = Beezync(config);
      for (var i = 0; i < 20; i++) {
        final d = real.debugBackoff(i);
        expect(d.inMilliseconds, inInclusiveRange(1000, 30000));
      }
      expect(real.debugBackoff(10).inMilliseconds, greaterThanOrEqualTo(24000));
    });
  });
}
