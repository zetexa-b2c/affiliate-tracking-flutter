import 'package:zet_affiliate_tracking/src/config.dart';
import 'package:zet_affiliate_tracking/src/link_parser.dart';
import 'package:zet_affiliate_tracking/src/uuid.dart';
import 'package:flutter_test/flutter_test.dart';

const _ref = ['ref'];
const _click = ['click_id', 'aff_click_id'];

AffiliateParams? fromUri(String link) =>
    paramsFromUri(Uri.parse(link), refParams: _ref, clickIdParams: _click);

AffiliateParams? fromReferrer(String referrer) =>
    paramsFromReferrer(referrer, refParams: _ref, clickIdParams: _click);

void main() {
  const clickId = '3f2b8c1e-9d4a-4b7e-8f21-0c5d6e7a8b9c';

  group('paramsFromUri', () {
    test('reads ref from an App Link or custom scheme', () {
      expect(fromUri('https://shop.example.com/app?ref=Ab3dE_f9')!.refCode, 'Ab3dE_f9');
      expect(fromUri('myshop://open?ref=Ab3dE_f9&utm_source=x')!.refCode, 'Ab3dE_f9');
    });

    test('ignores links without a ref', () {
      expect(fromUri('https://shop.example.com/product/12'), isNull);
      expect(fromUri('https://shop.example.com/?ref='), isNull);
      expect(fromUri('https://shop.example.com/?ref=%20%20'), isNull);
    });

    test('passes through a well-formed click id, lower-cased', () {
      final params = fromUri('https://x.test/?ref=abc&click_id=${clickId.toUpperCase()}');
      expect(params!.clickId, clickId);
      expect(fromUri('https://x.test/?ref=abc&aff_click_id=$clickId')!.clickId, clickId);
    });

    test('drops a click id that is not a UUID', () {
      final params = fromUri('https://x.test/?ref=abc&click_id=12345');
      expect(params!.refCode, 'abc');
      expect(params.clickId, isNull);
    });

    test('honours custom parameter names', () {
      final params = paramsFromUri(
        Uri.parse('https://x.test/?aff=abc'),
        refParams: const ['aff', 'ref'],
        clickIdParams: _click,
      );
      expect(params!.refCode, 'abc');
    });
  });

  group('paramsFromReferrer', () {
    test('parses the decoded Play referrer', () {
      final params = fromReferrer('ref=abc&click_id=$clickId');
      expect(params!.refCode, 'abc');
      expect(params.clickId, clickId);
    });

    test('handles a referrer that is still URL-encoded', () {
      expect(fromReferrer('ref%3Dabc%26click_id%3D$clickId')!.clickId, clickId);
    });

    test('returns null for organic installs', () {
      expect(fromReferrer('utm_source=google-play&utm_medium=organic'), isNull);
      expect(fromReferrer(''), isNull);
    });

    test('does not throw on malformed input', () {
      expect(fromReferrer('ref=%E0%A4%A'), isNull);
      expect(fromReferrer('%%%'), isNull);
    });

    test('reads campaign from install referrer', () {
      final params = fromReferrer(
        'ref=Ab3dE_f9&utm_campaign=winter_promo&utm_source=tiktok',
      );
      expect(params!.refCode, 'Ab3dE_f9');
      expect(params.campaign, 'winter_promo');
      expect(params.source, 'tiktok');
    });
  });

  group('campaign and UTM parsing from deep link', () {
    test('reads campaign, source, medium, and sub IDs', () {
      final params = fromUri(
        'https://shop.example.com/app?ref=Ab3dE_f9&utm_campaign=summer_26&utm_source=meta&utm_medium=cpc&sub1=ad_99&plan=usa_10gb',
      );
      expect(params!.refCode, 'Ab3dE_f9');
      expect(params.campaign, 'summer_26');
      expect(params.source, 'meta');
      expect(params.medium, 'cpc');
      expect(params.sub1, 'ad_99');
      expect(params.customParams['plan'], 'usa_10gb');
    });
  });

  group('AffiliateConfig endpoints', () {
    test('resolve under the base URL with or without a trailing slash', () {
      const a = AffiliateConfig(apiBaseUrl: 'https://track.example.com', trackingKey: 'k');
      const b = AffiliateConfig(apiBaseUrl: 'https://track.example.com/', trackingKey: 'k');
      expect('${a.clickEndpoint}', 'https://track.example.com/api/v1/t/click');
      expect('${b.conversionEndpoint}', 'https://track.example.com/api/v1/t/conversion');
      expect('${a.eventEndpoint}', 'https://track.example.com/api/v1/t/event');
    });

    test('keep a path prefix', () {
      const c = AffiliateConfig(apiBaseUrl: 'https://example.com/affiliates', trackingKey: 'k');
      expect('${c.clickEndpoint}', 'https://example.com/affiliates/api/v1/t/click');
      expect('${c.eventEndpoint}', 'https://example.com/affiliates/api/v1/t/event');
    });
  });

  test('uuidV4 produces valid, distinct v4 UUIDs', () {
    final ids = List.generate(200, (_) => uuidV4());
    expect(ids.every(isUuid), isTrue);
    expect(ids.toSet().length, ids.length);
    expect(ids.every((id) => id[14] == '4'), isTrue);
  });
}
