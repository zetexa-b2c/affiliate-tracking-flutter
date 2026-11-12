// Runs the SDK against a real affiliate-platform backend. Skipped unless it
// is pointed at one:
//
//   flutter test test/live_backend_test.dart \
//     --dart-define=E2E_API=http://127.0.0.1:8036 \
//     --dart-define=E2E_TRACKING_KEY=<program tracking key> \
//     --dart-define=E2E_REF=<an affiliate link's ref_code> \
//     --dart-define=E2E_COUPON=<that affiliate's coupon code>
//
// It creates real clicks and conversions, so use a scratch program.
import 'package:affiliate_tracking/affiliate_tracking.dart';
import 'package:affiliate_tracking/src/uuid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _api = String.fromEnvironment('E2E_API');
const _trackingKey = String.fromEnvironment('E2E_TRACKING_KEY');
const _ref = String.fromEnvironment('E2E_REF');
const _coupon = String.fromEnvironment('E2E_COUPON');

const _androidUa = 'Mozilla/5.0 (Linux; Android 14) Mobile affiliate_tracking/0.1.0';

class _StaticReferrer implements InstallReferrerSource {
  _StaticReferrer(this.referrer);
  final String referrer;

  @override
  Future<InstallReferrerDetails?> fetch() async => InstallReferrerDetails(
        referrer: referrer,
        clickTime: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      );
}

void main() {
  final skip = _api.isEmpty ? 'E2E_API not set' : null;
  late http.Client client;
  final run = DateTime.now().millisecondsSinceEpoch;

  setUp(() => client = http.Client());
  tearDown(() => client.close());

  Future<AffiliateTracker> start({InstallReferrerSource? referrer}) =>
      AffiliateTracker.create(
        config: const AffiliateConfig(apiBaseUrl: _api, trackingKey: _trackingKey),
        store: MemoryStore(),
        client: client,
        installReferrer: referrer,
        userAgent: _androidUa,
      );

  test('deep link → click → sale, and the same order again is a duplicate', () async {
    final tracker = await start();
    final attribution =
        await tracker.handleDeepLink(Uri.parse('https://shop.example.com/app?ref=$_ref'));
    expect(attribution, isNotNull);

    final result = await tracker.trackConversion(
      orderId: 'e2e-$run-sale',
      amount: 49.99,
      currency: 'USD',
    );
    expect(result.status, ConversionStatus.recorded, reason: '$result');
    expect(result.conversionId, isNotNull);
    expect(tracker.pendingEventCount, 0);

    final again = await tracker.trackConversion(orderId: 'e2e-$run-sale', amount: 49.99);
    expect(again.status, ConversionStatus.duplicate);
  }, skip: skip);

  test('referral code entered in the app', () async {
    final tracker = await start();
    await tracker.setReferralCode(_coupon.toLowerCase());
    final result = await tracker.trackConversion(orderId: 'e2e-$run-coupon', amount: 20);
    expect(result.status, ConversionStatus.recorded, reason: '$result');
  }, skip: skip);

  test('unknown ref code: click rejected, attribution dropped', () async {
    final tracker = await start();
    await tracker.handleDeepLink(Uri.parse('https://shop.example.com/app?ref=no-such-ref'));
    await tracker.flush();
    expect(tracker.attribution, isNull);
    final result = await tracker.trackConversion(orderId: 'e2e-$run-nope', amount: 5);
    expect(result.status, ConversionStatus.notAttributed);
  }, skip: skip);

  test('Play install referrer → click + app_install', () async {
    final tracker = await start(referrer: _StaticReferrer('ref=$_ref'));
    await tracker.ready;
    await tracker.flush();
    expect(tracker.attribution?.source, AttributionSource.installReferrer);
    expect(tracker.pendingEventCount, 0);

    final signup = await tracker.trackConversion(
      orderId: 'signup:e2e-$run',
      amount: 0,
      eventType: ConversionEventType.registration,
    );
    expect(signup.status, ConversionStatus.recorded, reason: '$signup');
  }, skip: skip);

  test('click id from the web snippet survives the Play Store install', () async {
    // What the snippet does on the landing page (a browser, so with Origin).
    final clickId = uuidV4();
    final web = await client.post(
      Uri.parse('$_api/api/v1/t/click'),
      headers: {'content-type': 'application/json', 'origin': 'https://shop.example.com'},
      body: '{"tracking_key":"$_trackingKey","ref_code":"$_ref","click_id":"$clickId"}',
    );
    expect(web.statusCode, 201, reason: web.body);

    // playStoreUrl() puts this in the referrer; the app reads it back.
    final tracker = await start(referrer: _StaticReferrer('ref=$_ref&click_id=$clickId'));
    await tracker.ready;
    await tracker.flush();
    expect(tracker.attribution?.clickId, clickId);
    expect(tracker.pendingEventCount, 0);

    final result = await tracker.trackConversion(orderId: 'e2e-$run-webapp', amount: 12.5);
    expect(result.status, ConversionStatus.recorded, reason: '$result');
    // ignore: avoid_print
    print('E2E_WEB_CLICK_ID=$clickId');
  }, skip: skip);
}
