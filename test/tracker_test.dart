import 'dart:async';
import 'dart:convert';

import 'package:affiliate_tracking/affiliate_tracking.dart';
import 'package:affiliate_tracking/src/api.dart';
import 'package:flutter_test/flutter_test.dart' hide Retry;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _key = 'test-tracking-key';
const _config = AffiliateConfig(apiBaseUrl: 'https://track.test', trackingKey: _key);
const _clickId = '3f2b8c1e-9d4a-4b7e-8f21-0c5d6e7a8b9c';

/// Stands in for the tracking API. Answers 201 unless a responder for the
/// path says otherwise, and throws (like a dead network) while [offline].
class FakeBackend {
  final requests = <http.Request>[];
  bool offline = false;
  http.Response Function(Map<String, dynamic> body)? onClick;
  http.Response Function(Map<String, dynamic> body)? onConversion;
  http.Response Function(Map<String, dynamic> body)? onEvent;
  http.Response Function(Map<String, dynamic> body)? onRefund;

  late final client = MockClient((request) async {
    if (offline) throw http.ClientException('Failed host lookup', request.url);
    requests.add(request);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final path = request.url.path;
    if (path == '/api/v1/t/click') {
      return onClick?.call(body) ?? _json(201, {'id': 'row', 'click_id': body['click_id']});
    }
    if (path == '/api/v1/t/conversion') {
      return onConversion?.call(body) ?? _json(201, {'id': 'conv-1', 'status': 'pending'});
    }
    if (path == '/api/v1/t/event') {
      return onEvent?.call(body) ?? _json(201, {'id': 'event-1', 'status': 'recorded'});
    }
    if (path == '/api/v1/t/refund') {
      return onRefund?.call(body) ?? _json(200, {'id': 'conv-1', 'status': 'reversed'});
    }
    return _json(404, {'detail': 'Not Found'});
  });

  List<Map<String, dynamic>> bodies(String kind) => requests
      .where((r) => r.url.path.endsWith('/$kind'))
      .map((r) => jsonDecode(r.body) as Map<String, dynamic>)
      .toList();
}

http.Response _json(int status, Object body) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// A store whose every operation fails, like a broken platform channel.
class BrokenStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => throw StateError('storage down');

  @override
  Future<void> write(String key, String value) async => throw StateError('storage down');

  @override
  Future<void> delete(String key) async => throw StateError('storage down');
}

/// Writes take a few milliseconds, like shared_preferences over a platform
/// channel, which opens the gaps real apps hit between awaits.
class SlowStore extends MemoryStore {
  @override
  Future<void> write(String key, String value) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await super.write(key, value);
  }
}

class FakeReferrer implements InstallReferrerSource {
  FakeReferrer(this.answer);
  Future<InstallReferrerDetails?> Function() answer;
  int calls = 0;

  @override
  Future<InstallReferrerDetails?> fetch() {
    calls++;
    return answer();
  }
}

void main() {
  late FakeBackend backend;
  late MemoryStore store;
  late DateTime now;

  setUp(() {
    backend = FakeBackend();
    store = MemoryStore();
    now = DateTime.utc(2026, 9, 25, 12);
  });

  Future<AffiliateTracker> start({
    AffiliateConfig config = _config,
    InstallReferrerSource? referrer,
    String? userAgent,
  }) async {
    final tracker = await AffiliateTracker.create(
      config: config,
      store: store,
      client: backend.client,
      installReferrer: referrer,
      userAgent: userAgent,
      now: () => now,
    );
    await tracker.ready;
    await tracker.flush();
    return tracker;
  }

  group('deep links', () {
    test('records a click and becomes the attribution', () async {
      final tracker = await start(userAgent: 'Mozilla/5.0 (Linux; Android 14) Mobile affiliate_tracking/0.1.0');
      final attribution =
          await tracker.handleDeepLink(Uri.parse('https://shop.test/app?ref=Ab3d&utm_source=ig'));
      await tracker.flush();

      expect(attribution!.refCode, 'Ab3d');
      expect(attribution.source, AttributionSource.deepLink);
      expect(tracker.attribution!.clickId, attribution.clickId);

      final click = backend.bodies('click').single;
      expect(click, {'tracking_key': _key, 'ref_code': 'Ab3d', 'click_id': attribution.clickId});
      final request = backend.requests.single;
      expect(request.headers['referer'], 'https://shop.test/app');
      expect(request.headers['user-agent'], contains('affiliate_tracking/'));
      expect(tracker.pendingEventCount, 0);
    });

    test('ignores links without a ref code', () async {
      final tracker = await start();
      expect(await tracker.handleDeepLink(Uri.parse('https://shop.test/product/1')), isNull);
      expect(backend.requests, isEmpty);
    });

    test('reuses a click id carried in the link', () async {
      final tracker = await start();
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc&click_id=$_clickId'));
      await tracker.flush();
      expect(backend.bodies('click').single['click_id'], _clickId);
    });

    test('does not count the same link twice within a day', () async {
      final tracker = await start();
      final link = Uri.parse('https://shop.test/?ref=abc');
      final first = await tracker.handleDeepLink(link);
      now = now.add(const Duration(hours: 2));
      final again = await tracker.handleDeepLink(link);
      await tracker.flush();
      expect(again!.clickId, first!.clickId);
      expect(backend.bodies('click'), hasLength(1));

      now = now.add(const Duration(days: 2));
      await tracker.handleDeepLink(link);
      await tracker.flush();
      expect(backend.bodies('click'), hasLength(2));
    });

    test('a newer link replaces the attribution (last touch wins)', () async {
      final tracker = await start();
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=first'));
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=second'));
      expect(tracker.attribution!.refCode, 'second');
    });

    test('a click the server rejects clears the attribution', () async {
      backend.onClick = (_) => _json(404, {'detail': 'Unknown ref_code for this program'});
      final tracker = await start();
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=bogus'));
      await tracker.flush();
      expect(tracker.attribution, isNull);
      expect(tracker.pendingEventCount, 0);
    });
  });

  group('conversions', () {
    test('without attribution nothing is sent', () async {
      final tracker = await start();
      final result = await tracker.trackConversion(orderId: 'o1', amount: 10);
      expect(result.status, ConversionStatus.notAttributed);
      expect(backend.requests, isEmpty);
    });

    test('with allowOrganic sends conversion without attribution', () async {
      final tracker = await start();
      final result = await tracker.trackConversion(orderId: 'o-org', amount: 19.99, allowOrganic: true);
      expect(result.status, ConversionStatus.recorded);
      expect(backend.requests.length, 1);
      final body = backend.bodies('conversion').single;
      expect(body['external_order_id'], 'o-org');
      expect(body['amount'], '19.99');
      expect(body.containsKey('click_id'), isFalse);
      expect(body.containsKey('coupon_code'), isFalse);
    });

    test('are credited to the current click', () async {
      final tracker = await start();
      final attribution = await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      final result = await tracker.trackConversion(
        orderId: 'ORD-1',
        amount: 49.99,
        currency: 'eur',
        eventType: ConversionEventType.sale,
      );

      expect(result.status, ConversionStatus.recorded);
      expect(result.conversionId, 'conv-1');
      expect(backend.bodies('conversion').single, {
        'tracking_key': _key,
        'click_id': attribution!.clickId,
        'external_order_id': 'ORD-1',
        'amount': '49.99',
        'currency': 'EUR',
        'event_type': 'sale',
      });
      // The click went first, so the server can resolve the click id.
      expect(backend.requests.map((r) => r.url.path), ['/api/v1/t/click', '/api/v1/t/conversion']);
    });

    test('use the referral code when that is the latest touch', () async {
      final tracker = await start();
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      await tracker.setReferralCode(' summer10 ');
      await tracker.trackConversion(orderId: 'o1', amount: 5);

      final body = backend.bodies('conversion').single;
      expect(body['coupon_code'], 'SUMMER10');
      expect(body.containsKey('click_id'), isFalse);
    });

    test('a coupon entered at checkout overrides the stored click', () async {
      final tracker = await start();
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      await tracker.trackConversion(orderId: 'o1', amount: 5, couponCode: 'friend20');

      final body = backend.bodies('conversion').single;
      expect(body['coupon_code'], 'FRIEND20');
      expect(body.containsKey('click_id'), isFalse);
      expect(tracker.attribution!.refCode, 'abc', reason: 'the override is per call');
    });

    test('409 means the order was already recorded', () async {
      backend.onConversion = (_) => _json(409, {'detail': 'already recorded'});
      final tracker = await start();
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      final result = await tracker.trackConversion(orderId: 'o1', amount: 5);
      expect(result.status, ConversionStatus.duplicate);
      expect(tracker.pendingEventCount, 0);
    });

    test('an expired attribution window is rejected and cleared', () async {
      backend.onConversion = (_) => _json(410, {'detail': 'Attribution window has expired for this click'});
      final tracker = await start();
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      final result = await tracker.trackConversion(orderId: 'o1', amount: 5);

      expect(result.status, ConversionStatus.rejected);
      expect(result.message, contains('expired'));
      expect(tracker.attribution, isNull);
    });

    test('a validation error is rejected but keeps the attribution', () async {
      backend.onConversion = (_) => _json(422, {
            'detail': [
              {'loc': ['body', 'amount'], 'msg': 'Input should be a valid decimal'}
            ]
          });
      final tracker = await start();
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      final result = await tracker.trackConversion(orderId: 'o1', amount: 5);
      expect(result.status, ConversionStatus.rejected);
      expect(result.message, contains('valid decimal'));
      expect(tracker.attribution, isNotNull);
    });

    test('validates its arguments', () async {
      final tracker = await start();
      expect(() => tracker.trackConversion(orderId: ' ', amount: 1), throwsArgumentError);
      expect(() => tracker.trackConversion(orderId: 'o', amount: -1), throwsArgumentError);
      expect(() => tracker.trackConversion(orderId: 'o', amount: double.nan), throwsArgumentError);
      expect(() => tracker.trackConversion(orderId: 'o', amount: 1, currency: 'dollars'),
          throwsArgumentError);
      expect(() => tracker.setReferralCode('  '), throwsArgumentError);
    });
  });

  group('offline queue', () {
    test('queues while offline and delivers in order once back', () async {
      final tracker = await start();
      backend.offline = true;
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      final result = await tracker.trackConversion(orderId: 'o1', amount: 20);

      expect(result.status, ConversionStatus.queued);
      expect(tracker.pendingEventCount, 2);
      expect(backend.requests, isEmpty);

      backend.offline = false;
      await tracker.flush();
      expect(tracker.pendingEventCount, 0);
      expect(backend.requests.map((r) => r.url.path), ['/api/v1/t/click', '/api/v1/t/conversion']);
    });

    test('survives an app restart', () async {
      var tracker = await start();
      backend.offline = true;
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      await tracker.trackConversion(orderId: 'o1', amount: 20);
      final clickId = tracker.attribution!.clickId;
      tracker.dispose();

      backend.offline = false;
      tracker = await start(); // same store: a relaunch
      expect(tracker.attribution!.clickId, clickId);
      expect(tracker.pendingEventCount, 0);
      expect(backend.bodies('conversion').single['click_id'], clickId);
    });

    test('a server error on the click holds back the conversion', () async {
      var clickFails = true;
      backend.onClick = (body) => clickFails
          ? _json(503, {'detail': 'down'})
          : _json(201, {'click_id': body['click_id']});
      final tracker = await start();
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      final result = await tracker.trackConversion(orderId: 'o1', amount: 20);

      expect(result.status, ConversionStatus.queued);
      expect(backend.bodies('conversion'), isEmpty);

      clickFails = false;
      await tracker.flush();
      expect(backend.bodies('conversion'), hasLength(1));
      tracker.dispose();
    });

    test('drops events older than maxEventAge', () async {
      final tracker = await start(
        config: const AffiliateConfig(
          apiBaseUrl: 'https://track.test',
          trackingKey: _key,
          maxEventAge: Duration(days: 7),
        ),
      );
      backend.offline = true;
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      await tracker.flush(); // let the background attempt fail while offline
      expect(tracker.pendingEventCount, 1);

      now = now.add(const Duration(days: 8));
      backend.offline = false;
      await tracker.flush();
      expect(tracker.pendingEventCount, 0);
      expect(backend.requests, isEmpty);
    });
  });

  group('install referrer', () {
    InstallReferrerDetails details(String referrer) => InstallReferrerDetails(
          referrer: referrer,
          clickTime: DateTime.utc(2026, 9, 25, 11),
        );

    test('attributes the install and reports app_install once', () async {
      final referrer = FakeReferrer(() async => details('ref=abc&click_id=$_clickId'));
      var tracker = await start(referrer: referrer);

      expect(tracker.attribution!.source, AttributionSource.installReferrer);
      expect(tracker.attribution!.clickId, _clickId);
      expect(backend.bodies('click').single['click_id'], _clickId);
      expect(backend.bodies('conversion').single, {
        'tracking_key': _key,
        'click_id': _clickId,
        'external_order_id': 'app_install:${tracker.installId}',
        'amount': '0',
        'currency': 'USD',
        'event_type': 'app_install',
      });

      tracker.dispose();
      tracker = await start(referrer: referrer);
      expect(referrer.calls, 1, reason: 'read once per install');
      expect(backend.requests, hasLength(2));
    });

    test('reportInstalls: false records only the click', () async {
      await start(
        config: const AffiliateConfig(
          apiBaseUrl: 'https://track.test',
          trackingKey: _key,
          reportInstalls: false,
        ),
        referrer: FakeReferrer(() async => details('ref=abc')),
      );
      expect(backend.bodies('click'), hasLength(1));
      expect(backend.bodies('conversion'), isEmpty);
    });

    test('organic installs send nothing', () async {
      final tracker = await start(
        referrer: FakeReferrer(() async => details('utm_source=google-play&utm_medium=organic')),
      );
      expect(tracker.attribution, isNull);
      expect(backend.requests, isEmpty);
    });

    test('a transient failure is retried on the next launch', () async {
      var fail = true;
      final referrer = FakeReferrer(() async {
        if (fail) throw const InstallReferrerException('SERVICE_UNAVAILABLE', permanent: false);
        return details('ref=abc');
      });
      var tracker = await start(referrer: referrer);
      expect(tracker.attribution, isNull);

      fail = false;
      tracker.dispose();
      tracker = await start(referrer: referrer);
      expect(referrer.calls, 2);
      expect(tracker.attribution!.refCode, 'abc');
    });

    test('a permanent failure is not retried', () async {
      final referrer = FakeReferrer(
        () async => throw const InstallReferrerException('FEATURE_NOT_SUPPORTED', permanent: true),
      );
      var tracker = await start(referrer: referrer);
      tracker.dispose();
      tracker = await start(referrer: referrer);
      expect(referrer.calls, 1);
    });

    test('a first conversion waits for the referrer', () async {
      final tracker = await AffiliateTracker.create(
        config: _config,
        store: store,
        client: backend.client,
        installReferrer: FakeReferrer(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return details('ref=abc');
        }),
        now: () => now,
      );
      // No await on ready: trackConversion has to wait by itself.
      final result = await tracker.trackConversion(orderId: 'signup:42', amount: 0,
          eventType: ConversionEventType.registration);
      expect(result.status, ConversionStatus.recorded);
      expect(backend.bodies('conversion').last['event_type'], 'registration');
    });

    test('keeps a deep link opened after the Play Store click', () async {
      final tracker = await AffiliateTracker.create(
        config: _config,
        store: store,
        client: backend.client,
        installReferrer: FakeReferrer(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return details('ref=from_play'); // clicked at 11:00
        }),
        now: () => now, // 12:00
      );
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=from_link'));
      await tracker.ready;
      expect(tracker.attribution!.refCode, 'from_link');
    });
  });

  group('review regressions', () {
    test('a conversion right after an un-awaited deep link waits for its click', () async {
      store = SlowStore();
      final tracker = await start();
      // Link plugins call handlers without awaiting them.
      unawaited(tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc')));
      final result = await tracker.trackConversion(
        orderId: 'lead-1',
        amount: 0,
        eventType: ConversionEventType.lead,
      );

      expect(result.status, ConversionStatus.recorded);
      expect(backend.requests.map((r) => r.url.path), ['/api/v1/t/click', '/api/v1/t/conversion']);
      expect(tracker.attribution, isNotNull);
    });

    test('the same launch link delivered twice at once is one click', () async {
      final tracker = await start();
      final link = Uri.parse('https://shop.test/?ref=abc');
      final both = await Future.wait([tracker.handleDeepLink(link), tracker.handleDeepLink(link)]);
      await tracker.flush();
      expect(both[0]!.clickId, both[1]!.clickId);
      expect(backend.bodies('click'), hasLength(1));
    });

    test('responses that are not about the event are retried, not dropped', () {
      SendResult click(int status, String body) =>
          TrackingApi.classify(EventKind.click, status, body);
      expect(click(308, ''), isA<Retry>());
      expect(click(403, '<html>Access denied</html>'), isA<Retry>());
      expect(click(404, '{"detail":"Not Found"}'), isA<Retry>());
      expect(click(404, '{"detail":"Unknown tracking_key"}'), isA<Retry>());
      expect(click(429, '{"detail":"slow down"}'), isA<Retry>());
      expect(click(404, '{"detail":"Unknown ref_code for this program"}'), isA<Rejected>());
      expect(click(403, '{"detail":"Origin not allowed for this program"}'), isA<Rejected>());
      expect(TrackingApi.classify(EventKind.conversion, 409, '{}'), isA<Duplicate>());
    });

    test('a client error that is not an Exception queues instead of throwing', () async {
      final tracker = await AffiliateTracker.create(
        config: _config,
        store: store,
        client: MockClient(
          (_) async => throw StateError('Insecure HTTP is not allowed by platform'),
        ),
        now: () => now,
      );
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      final result = await tracker.trackConversion(orderId: 'o1', amount: 1);
      expect(result.status, ConversionStatus.queued);
      expect(tracker.pendingEventCount, 2);
      tracker.dispose();
    });

    test('broken storage never surfaces as an exception', () async {
      final tracker = await AffiliateTracker.create(
        config: _config,
        store: BrokenStore(),
        client: backend.client,
        now: () => now,
      );
      await tracker.handleDeepLink(Uri.parse('https://shop.test/?ref=abc'));
      final result = await tracker.trackConversion(orderId: 'o1', amount: 1);
      expect(result.status, ConversionStatus.recorded);
    });

    group('install referrer and app updates', () {
      const key = '0f8fad5b-d9cb-369f-a165-70867728950e';
      final installedLongAgo = DateTime.utc(2026, 5, 1);

      InstallReferrerDetails referrer({required DateTime installed, required DateTime updated}) =>
          InstallReferrerDetails(
            referrer: 'ref=abc',
            clickTime: installed.subtract(const Duration(minutes: 1)),
            firstInstallTime: installed,
            lastUpdateTime: updated,
            installKey: key,
          );

      test('an old install updated to the SDK version is ignored', () async {
        final tracker = await start(
          referrer: FakeReferrer(
            () async => referrer(installed: installedLongAgo, updated: DateTime.utc(2026, 9, 24)),
          ),
        );
        expect(tracker.attribution, isNull);
        expect(backend.requests, isEmpty);
      });

      test('a recent install that was updated still counts', () async {
        final tracker = await start(
          referrer: FakeReferrer(
            () async => referrer(
              installed: now.subtract(const Duration(days: 2)),
              updated: now.subtract(const Duration(days: 1)),
            ),
          ),
        );
        expect(tracker.attribution?.refCode, 'abc');
      });

      test('a never-updated install counts however old it is', () async {
        final tracker = await start(
          referrer: FakeReferrer(
            () async => referrer(installed: installedLongAgo, updated: installedLongAgo),
          ),
        );
        expect(tracker.attribution?.refCode, 'abc');
      });

      test('the install key keeps ids stable after a data clear', () async {
        final source = FakeReferrer(
          () async => referrer(installed: installedLongAgo, updated: installedLongAgo),
        );
        var tracker = await start(referrer: source);
        expect(tracker.attribution!.clickId, key);
        expect(backend.bodies('conversion').single['external_order_id'], 'app_install:$key');

        tracker.dispose();
        store = MemoryStore(); // "Clear storage"
        tracker = await start(referrer: source);
        expect(backend.bodies('click').map((b) => b['click_id']).toSet(), {key});
        expect(
          backend.bodies('conversion').map((b) => b['external_order_id']).toSet(),
          {'app_install:$key'},
        );
      });
    });

    test('a tracker replaced mid-lookup does not record the install twice', () async {
      final slow = FakeReferrer(() async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return InstallReferrerDetails(referrer: 'ref=abc', clickTime: now);
      });
      await AffiliateTracker.create(
        config: _config,
        store: store,
        client: backend.client,
        installReferrer: slow,
        now: () => now,
      );
      // init called again straight away, e.g. from a second entry point.
      final second = await start(referrer: slow);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await second.flush();

      expect(backend.bodies('click'), hasLength(1));
      expect(backend.bodies('conversion'), hasLength(1));
      expect(second.attribution?.refCode, 'abc');
    });

    test('clearing the attribution during the lookup is not undone', () async {
      final tracker = await AffiliateTracker.create(
        config: _config,
        store: store,
        client: backend.client,
        installReferrer: FakeReferrer(() async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return const InstallReferrerDetails(referrer: 'ref=abc'); // no click time
        }),
        now: () => now,
      );
      await tracker.clearAttribution();
      await tracker.ready;
      expect(tracker.attribution, isNull);
    });
  });

  test('instance is available after create and cleared on dispose', () async {
    final tracker = await start();
    expect(AffiliateTracker.instance, same(tracker));
    tracker.dispose();
    expect(AffiliateTracker.isInitialized, isFalse);
    expect(() => AffiliateTracker.instance, throwsStateError);
  });

  group('customer user ID', () {
    test('persists customerUserId across tracker instances', () async {
      final t1 = await start();
      await t1.setCustomerUserId('user_12345');
      expect(t1.customerUserId, 'user_12345');
      t1.dispose();

      final t2 = await start();
      expect(t2.customerUserId, 'user_12345');
      await t2.setCustomerUserId(null);
      expect(t2.customerUserId, isNull);
      t2.dispose();

      final t3 = await start();
      expect(t3.customerUserId, isNull);
    });

    test('attaches customerUserId and metadata to conversion', () async {
      final tracker = await start();
      await tracker.setCustomerUserId('user_vip_99');
      await tracker.handleDeepLink(Uri.parse('https://shop.test/app?ref=Ab3d'));
      await tracker.flush();

      await tracker.trackConversion(
        orderId: 'order_abc',
        amount: 25.50,
        currency: 'USD',
        metadata: {
          'plan_id': 'usa_10gb',
          'plan_name': 'USA 10GB 30D',
          'country_code': 'US',
        },
      );

      final conversion = backend.bodies('conversion').single;
      expect(conversion['customer_user_id'], 'user_vip_99');
      expect(conversion['external_order_id'], 'order_abc');
      expect((conversion['metadata'] as Map)['plan_id'], 'usa_10gb');
      expect((conversion['metadata'] as Map)['plan_name'], 'USA 10GB 30D');
    });
  });

  group('trackEvent (in-app funnel)', () {
    test('delivers custom in-app events with properties and attribution', () async {
      final tracker = await start();
      await tracker.setCustomerUserId('user_vip_99');
      await tracker.handleDeepLink(Uri.parse('https://shop.test/app?ref=Ab3d'));
      await tracker.flush();

      final result = await tracker.trackEvent(
        eventName: EventNames.viewPlan,
        properties: {
          'plan_id': 'esim_usa_10gb',
          'price': 15.00,
          'currency': 'USD',
        },
      );

      expect(result.status, EventStatus.recorded);
      final eventBody = backend.bodies('event').single;
      expect(eventBody['event_name'], 'view_plan');
      expect(eventBody['click_id'], tracker.attribution!.clickId);
      expect(eventBody['customer_user_id'], 'user_vip_99');
      expect((eventBody['properties'] as Map)['plan_id'], 'esim_usa_10gb');
    });

    test('validates event name', () async {
      final tracker = await start();
      expect(
        () => tracker.trackEvent(eventName: '   '),
        throwsArgumentError,
      );
    });
  });

  group('campaign attribution in deep links', () {
    test('captures campaign and UTM parameters into attribution', () async {
      final tracker = await start();
      final attr = await tracker.handleDeepLink(Uri.parse(
        'https://shop.test/app?ref=Ab3d&utm_campaign=summer_sale&utm_source=instagram&utm_medium=story&sub1=influencer_1&custom_tag=promo',
      ));

      expect(attr!.refCode, 'Ab3d');
      expect(attr.campaign, 'summer_sale');
      expect(attr.trafficSource, 'instagram');
      expect(attr.medium, 'story');
      expect(attr.sub1, 'influencer_1');
      expect(attr.customParameters['custom_tag'], 'promo');

      // Verify persistence
      final json = attr.toJson();
      final restored = Attribution.fromJson(json);
      expect(restored!.campaign, 'summer_sale');
      expect(restored.trafficSource, 'instagram');
      expect(restored.medium, 'story');
      expect(restored.sub1, 'influencer_1');
      expect(restored.customParameters['custom_tag'], 'promo');
    });
  });

  group('trackRefund', () {
    test('sends nothing and says refunds come from the server', () async {
      final tracker = await start();
      // ignore: deprecated_member_use_from_same_package
      final result = await tracker.trackRefund(
        orderId: 'ORDER-12345',
        refundAmount: 15.50,
        reason: 'Customer requested cancellation',
      );

      expect(result.status, ConversionStatus.rejected);
      expect(result.message, AffiliateTracker.refundFromServerMessage);
      expect(backend.bodies('refund'), isEmpty);
    });
  });
}
