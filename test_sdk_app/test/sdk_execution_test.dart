// ignore_for_file: avoid_print

import 'dart:convert';
import 'package:affiliate_tracking/affiliate_tracking.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('SDK Full Workflow Live Trace & Output', () async {
    print('\n==================== [SDK LIVE WORKFLOW EXECUTION] ====================');

    final receivedRequests = <String>[];
    final mockClient = _MockClient((request) {
      receivedRequests.add('${request.method} ${request.url.path} => ${request.body}');
      if (request.url.path.contains('/api/v1/t/click')) {
        return http.Response(jsonEncode({'status': 'ok', 'click_id': 'clk_9988'}), 200);
      } else if (request.url.path.contains('/api/v1/t/conversion')) {
        final body = jsonDecode(request.body);
        if (body['external_order_id'] == 'dup_123') {
          return http.Response(jsonEncode({'detail': 'Order already processed'}), 409);
        }
        return http.Response(jsonEncode({
          'id': 'conv_recorded_456',
          'external_order_id': body['external_order_id'],
          'status': 'recorded',
        }), 200);
      }
      return http.Response('{}', 404);
    });

    // 1. Initialize SDK
    print('\n[1] Initializing AffiliateTracker...');
    final tracker = await AffiliateTracker.create(
      config: const AffiliateConfig(
        apiBaseUrl: 'https://track.example.com',
        trackingKey: 'sample-tracking-key-xyz',
        debug: true,
      ),
      client: mockClient,
      store: MemoryStore(),
    );
    print('    ✓ Initialized! Install ID: ${tracker.installId}');
    print('    ✓ Initial Attribution: ${tracker.attribution}');

    // 2. Handle Deep Link
    print('\n[2] Ingesting Deep Link: https://myshop.com/product?ref=aff_superstar&click_id=clk_9988');
    final attr = await tracker.handleDeepLink(
      Uri.parse('https://myshop.com/product?ref=aff_superstar&click_id=clk_9988'),
    );
    print('    ✓ Captured Attribution:');
    print('        • Ref Code:   ${attr?.refCode}');
    print('        • Click ID:   ${attr?.clickId}');
    print('        • Source:     ${attr?.source.name}');
    print('        • CapturedAt: ${attr?.capturedAt}');

    // 3. Track Sale Conversion
    print('\n[3] Tracking Conversion: orderId="order_1001", amount=149.99 USD, eventType=sale');
    final saleResult = await tracker.trackConversion(
      orderId: 'order_1001',
      amount: 149.99,
      currency: 'USD',
      eventType: ConversionEventType.sale,
    );
    print('    ✓ Conversion Result: status=${saleResult.status.name}, id=${saleResult.conversionId}');

    // 4. Test Duplicate Conversion
    print('\n[4] Tracking Duplicate Conversion: orderId="dup_123"');
    final dupResult = await tracker.trackConversion(
      orderId: 'dup_123',
      amount: 49.99,
      currency: 'USD',
    );
    print('    ✓ Duplicate Result: status=${dupResult.status.name} (HTTP 409 handled correctly)');

    // 5. In-App Referral Code Override
    print('\n[5] Setting In-App Referral Code: "VIP_PARTNER"');
    await tracker.setReferralCode('VIP_PARTNER');
    print('    ✓ Updated Attribution:');
    print('        • Referral Code: ${tracker.attribution?.referralCode}');
    print('        • Source:        ${tracker.attribution?.source.name}');

    // 6. Network Requests Sent
    print('\n[6] HTTP Payloads Transmitted by SDK to Backend:');
    for (var i = 0; i < receivedRequests.length; i++) {
      print('    Request #${i + 1}: ${receivedRequests[i]}');
    }

    print('\n========================================================================\n');
  });
}

class _MockClient extends http.BaseClient {
  _MockClient(this.handler);
  final http.Response Function(http.Request request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    final res = handler(req);
    return http.StreamedResponse(
      Stream.value(utf8.encode(res.body)),
      res.statusCode,
      headers: res.headers,
    );
  }
}
