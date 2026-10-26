import 'dart:async';
import 'dart:convert';
import 'package:affiliate_tracking/affiliate_tracking.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AffiliateSdkTestApp());
}

class AffiliateSdkTestApp extends StatelessWidget {
  const AffiliateSdkTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Affiliate SDK Tester (AppsFlyer Style)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F46E5),
          brightness: Brightness.light,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade300),
          ),
        ),
      ),
      home: const SdkDashboardPage(),
    );
  }
}

class SdkDashboardPage extends StatefulWidget {
  const SdkDashboardPage({super.key});

  @override
  State<SdkDashboardPage> createState() => _SdkDashboardPageState();
}

class _SdkDashboardPageState extends State<SdkDashboardPage> {
  bool _initialized = false;
  bool _mockBackend = true;
  final String _apiBaseUrl = 'https://track.example.com';
  final String _trackingKey = 'program-track-key-1234';

  final TextEditingController _urlController = TextEditingController(
    text: 'https://myshop.com/product?ref=aff_superstar&utm_campaign=summer_2026&utm_source=instagram&sub1=ad_42&click_id=clk_9988',
  );
  final TextEditingController _refCodeController = TextEditingController(
    text: 'SUMMER2026',
  );
  final TextEditingController _userIdController = TextEditingController(
    text: 'user_102030@zetsim.com',
  );
  final TextEditingController _orderIdController = TextEditingController(
    text: 'ord_${DateTime.now().millisecondsSinceEpoch}',
  );
  final TextEditingController _amountController = TextEditingController(
    text: '24.99',
  );
  final TextEditingController _currencyController = TextEditingController(
    text: 'USD',
  );
  final TextEditingController _couponOverrideController = TextEditingController();

  // Plan Details (Metadata)
  final TextEditingController _planIdController = TextEditingController(
    text: 'usa_10gb_30d',
  );
  final TextEditingController _planNameController = TextEditingController(
    text: 'USA 10GB - 30 Days',
  );
  final TextEditingController _countryCodeController = TextEditingController(
    text: 'US',
  );

  ConversionEventType _eventType = ConversionEventType.sale;
  final List<String> _logs = [];

  // Mock server received events
  final List<Map<String, dynamic>> _mockReceivedClicks = [];
  final List<Map<String, dynamic>> _mockReceivedEvents = [];
  final List<Map<String, dynamic>> _mockReceivedConversions = [];

  @override
  void initState() {
    super.initState();
    _initSdk();
  }

  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _logs.insert(0, '[$timestamp] $message');
    });
  }

  Future<void> _initSdk() async {
    _log('Initializing AffiliateTracker SDK (Mock: $_mockBackend)...');
    try {
      final config = AffiliateConfig(
        apiBaseUrl: _apiBaseUrl,
        trackingKey: _trackingKey,
        debug: true,
      );

      if (_mockBackend) {
        final mockClient = _createMockClient();
        await AffiliateTracker.create(
          config: config,
          client: mockClient,
          store: MemoryStore(),
        );
      } else {
        await AffiliateTracker.init(config);
      }

      setState(() {
        _initialized = true;
      });
      _log('SDK Initialized successfully!');
      _log('Install ID: ${AffiliateTracker.instance.installId}');
    } catch (e) {
      _log('Initialization error: $e');
    }
  }

  http.Client _createMockClient() {
    return _MockTrackingHttpClient(
      onPost: (url, headers, body) {
        final path = url.path;
        final decoded = jsonDecode(body) as Map<String, dynamic>;

        if (path.contains('/api/v1/t/click')) {
          _mockReceivedClicks.insert(0, {
            'time': DateTime.now().toIso8601String().substring(11, 19),
            'url': url.toString(),
            'body': decoded,
            'headers': headers,
          });
          _log('Mock: Click ref=${decoded['ref_code']} click_id=${decoded['click_id']}');
          return http.Response(
            jsonEncode({'status': 'ok', 'click_id': decoded['click_id'] ?? 'clk_mock_generated'}),
            200,
          );
        } else if (path.contains('/api/v1/t/event')) {
          _mockReceivedEvents.insert(0, {
            'time': DateTime.now().toIso8601String().substring(11, 19),
            'url': url.toString(),
            'body': decoded,
            'headers': headers,
          });
          _log('Mock: In-App Event name=${decoded['event_name']}, user=${decoded['customer_user_id']}');
          return http.Response(
            jsonEncode({
              'id': 'evt_${DateTime.now().millisecondsSinceEpoch}',
              'event_name': decoded['event_name'],
              'status': 'recorded',
            }),
            200,
          );
        } else if (path.contains('/api/v1/t/conversion')) {
          _mockReceivedConversions.insert(0, {
            'time': DateTime.now().toIso8601String().substring(11, 19),
            'url': url.toString(),
            'body': decoded,
            'headers': headers,
          });
          final orderId = decoded['external_order_id'];
          if (orderId == 'duplicate-test') {
            _log('Mock: 409 Conflict (Duplicate order)');
            return http.Response(jsonEncode({'detail': 'Order already processed'}), 409);
          }
          _log('Mock: Conversion order=$orderId, amount=${decoded['amount']} ${decoded['currency']}');
          return http.Response(
            jsonEncode({
              'id': 'conv_${DateTime.now().millisecondsSinceEpoch}',
              'external_order_id': orderId,
              'status': 'recorded',
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'detail': 'Not Found'}), 404);
      },
    );
  }

  Future<void> _handleDeepLink() async {
    if (!_initialized) return;
    final urlStr = _urlController.text.trim();
    if (urlStr.isEmpty) return;

    final uri = Uri.tryParse(urlStr);
    if (uri == null) {
      _log('Error: Invalid URI format');
      return;
    }

    _log('Processing deep link: $uri');
    final attribution = await AffiliateTracker.instance.handleDeepLink(uri);
    if (attribution == null) {
      _log('Link ignored: No ref or duplicate suppressed.');
    } else {
      _log('Attributed: ref=${attribution.refCode}, campaign=${attribution.campaign}, source=${attribution.trafficSource}');
    }
    setState(() {});
  }

  Future<void> _setReferralCode() async {
    if (!_initialized) return;
    final code = _refCodeController.text.trim();
    if (code.isEmpty) return;

    try {
      _log('Setting manual referral code: $code');
      await AffiliateTracker.instance.setReferralCode(code);
      final attr = AffiliateTracker.instance.attribution;
      _log('Referral attributed: code=${attr?.referralCode}');
    } catch (e) {
      _log('Error setting referral code: $e');
    }
    setState(() {});
  }

  Future<void> _setCustomerUserId() async {
    if (!_initialized) return;
    final id = _userIdController.text.trim();
    _log('Setting Customer User ID: $id');
    await AffiliateTracker.instance.setCustomerUserId(id);
    _log('Customer User ID set: ${AffiliateTracker.instance.customerUserId}');
    setState(() {});
  }

  Future<void> _clearCustomerUserId() async {
    if (!_initialized) return;
    _log('Clearing Customer User ID...');
    await AffiliateTracker.instance.setCustomerUserId(null);
    _userIdController.clear();
    _log('Customer User ID cleared.');
    setState(() {});
  }

  Future<void> _trackFunnelEvent(String eventName, [Map<String, Object?>? customProps]) async {
    if (!_initialized) return;
    final props = customProps ?? {
      'plan_id': _planIdController.text.trim(),
      'plan_name': _planNameController.text.trim(),
      'country_code': _countryCodeController.text.trim(),
      'amount': double.tryParse(_amountController.text.trim()) ?? 24.99,
      'currency': _currencyController.text.trim(),
    };

    _log('Tracking event "$eventName"...');
    final result = await AffiliateTracker.instance.trackEvent(
      eventName: eventName,
      properties: props,
    );
    _log('Event result: status=${result.status.name}${result.message != null ? ", msg=${result.message}" : ""}');
    setState(() {});
  }

  Future<void> _trackConversion() async {
    if (!_initialized) return;
    final orderId = _orderIdController.text.trim();
    final amount = double.tryParse(_amountController.text.trim()) ?? 24.99;
    final currency = _currencyController.text.trim();
    final coupon = _couponOverrideController.text.trim().isEmpty ? null : _couponOverrideController.text.trim();

    final metadata = {
      'plan_id': _planIdController.text.trim(),
      'plan_name': _planNameController.text.trim(),
      'country_code': _countryCodeController.text.trim(),
      'validity_days': 30,
      'data_gb': 10,
    };

    _log('Tracking conversion: orderId=$orderId, amount=$amount $currency (plan: ${_planIdController.text.trim()})');
    final result = await AffiliateTracker.instance.trackConversion(
      orderId: orderId,
      amount: amount,
      currency: currency,
      eventType: _eventType,
      couponCode: coupon,
      metadata: metadata,
    );

    _log('Recorded Conversion: status=${result.status.name}, id=${result.conversionId}');
    _orderIdController.text = 'ord_${DateTime.now().millisecondsSinceEpoch}';
    setState(() {});
  }

  Future<void> _flush() async {
    if (!_initialized) return;
    _log('Flushing event queue...');
    await AffiliateTracker.instance.flush();
    _log('Flush done. Pending: ${AffiliateTracker.instance.pendingEventCount}');
    setState(() {});
  }

  Future<void> _clearAttribution() async {
    if (!_initialized) return;
    _log('Clearing attribution...');
    await AffiliateTracker.instance.clearAttribution();
    _log('Attribution cleared.');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tracker = _initialized ? AffiliateTracker.instance : null;
    final attribution = tracker?.attribution;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Affiliate SDK Inspector & Tester', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          actions: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Mock', style: TextStyle(fontSize: 11)),
                Switch(
                  value: _mockBackend,
                  onChanged: (val) {
                    setState(() {
                      _mockBackend = val;
                    });
                    _initSdk();
                  },
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: 'Re-initialize SDK',
              onPressed: _initSdk,
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 700;
            if (isDesktop) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 6,
                    child: _buildControlsList(tracker, attribution),
                  ),
                  Expanded(
                    flex: 5,
                    child: _buildInspectorColumn(),
                  ),
                ],
              );
            } else {
              return Column(
                children: [
                  const Material(
                    color: Colors.white,
                    elevation: 1,
                    child: TabBar(
                      tabs: [
                        Tab(icon: Icon(Icons.touch_app, size: 18), text: 'SDK Controls'),
                        Tab(icon: Icon(Icons.list_alt, size: 18), text: 'Logs & Inspector'),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildControlsList(tracker, attribution),
                        _buildInspectorColumn(),
                      ],
                    ),
                  ),
                ],
              );
            }
          },
        ),
      ),
    );
  }

  Widget _buildControlsList(AffiliateTracker? tracker, Attribution? attribution) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildStatusBanner(tracker, attribution),
          const SizedBox(height: 12),
          _buildUserIdentityCard(tracker),
          const SizedBox(height: 12),
          _buildDeepLinkCard(),
          const SizedBox(height: 12),
          _buildInAppEventsCard(),
          const SizedBox(height: 12),
          _buildReferralCodeCard(),
          const SizedBox(height: 12),
          _buildConversionCard(),
          const SizedBox(height: 12),
          _buildQueueAndResetCard(tracker),
        ],
      ),
    );
  }

  Widget _buildInspectorColumn() {
    return Container(
      color: Colors.grey.shade50,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Live SDK Logs', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              TextButton.icon(
                icon: const Icon(Icons.clear, size: 14),
                label: const Text('Clear', style: TextStyle(fontSize: 12)),
                onPressed: () => setState(() => _logs.clear()),
              ),
            ],
          ),
          Expanded(
            flex: 4,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E2E),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: _logs.isEmpty
                  ? const Center(child: Text('No logs yet', style: TextStyle(color: Colors.white54, fontSize: 12)))
                  : ListView.builder(
                      itemCount: _logs.length,
                      itemBuilder: (context, i) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: SelectableText(
                            _logs[i],
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Color(0xFFA6E3A1),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 10),
          const Text('Backend Transmitted Events', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 6),
          Expanded(
            flex: 5,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: (_mockReceivedClicks.isEmpty && _mockReceivedEvents.isEmpty && _mockReceivedConversions.isEmpty)
                  ? const Center(child: Text('No network events yet', style: TextStyle(color: Colors.black45, fontSize: 12)))
                  : ListView(
                      padding: const EdgeInsets.all(8),
                      children: [
                        if (_mockReceivedClicks.isNotEmpty) ...[
                          const Text('Clicks (Touches):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 12)),
                          ..._mockReceivedClicks.map((c) => _buildPayloadCard(c, Colors.blue.shade50)),
                        ],
                        if (_mockReceivedEvents.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          const Text('In-App Journey Events:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.purple, fontSize: 12)),
                          ..._mockReceivedEvents.map((evt) => _buildPayloadCard(evt, Colors.purple.shade50)),
                        ],
                        if (_mockReceivedConversions.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          const Text('Purchases & Conversions:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green, fontSize: 12)),
                          ..._mockReceivedConversions.map((conv) => _buildPayloadCard(conv, Colors.green.shade50)),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPayloadCard(Map<String, dynamic> item, Color bg) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('[${item['time']}] ${item['url']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
          const SizedBox(height: 2),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(item['body']),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner(AffiliateTracker? tracker, Attribution? attribution) {
    return Card(
      color: Colors.indigo.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              spacing: 8,
              runSpacing: 4,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _initialized ? Icons.check_circle : Icons.error,
                      color: _initialized ? Colors.green : Colors.red,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _initialized ? 'SDK Active & Ready' : 'SDK Not Initialized',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ],
                ),
                Chip(
                  label: Text('Queue: ${tracker?.pendingEventCount ?? 0}', style: const TextStyle(fontSize: 10)),
                  backgroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
            const Divider(height: 12),
            Text('• Install ID: ${tracker?.installId ?? "—"}', style: const TextStyle(fontSize: 11)),
            Text('• Customer User ID: ${tracker?.customerUserId ?? "Anonymous (not set)"}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: Colors.indigo)),
            Text('• Attribution Status: ${attribution == null ? "None (Unattributed)" : "Active"}', style: const TextStyle(fontSize: 11)),
            if (attribution != null) ...[
              Text('  - Ref Code: ${attribution.refCode ?? "—"}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
              Text('  - Click ID: ${attribution.clickId ?? "—"}', style: const TextStyle(fontSize: 11)),
              if (attribution.campaign != null)
                Text('  - Campaign: ${attribution.campaign}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: Colors.deepPurple)),
              if (attribution.trafficSource != null)
                Text('  - Source / Medium: ${attribution.trafficSource} / ${attribution.medium ?? "—"}', style: const TextStyle(fontSize: 11)),
              if (attribution.sub1 != null)
                Text('  - Sub ID: ${attribution.sub1}', style: const TextStyle(fontSize: 11)),
              Text('  - Referral / Coupon: ${attribution.referralCode ?? "—"}', style: const TextStyle(fontSize: 11)),
              Text('  - Source: ${attribution.source.name}', style: const TextStyle(fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildUserIdentityCard(AffiliateTracker? tracker) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Customer User Identity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            const Text('Links anonymous attribution touches with user account in ZetSim.', style: TextStyle(fontSize: 11, color: Colors.black54)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _userIdController,
                    decoration: const InputDecoration(labelText: 'Customer User ID / Email', border: OutlineInputBorder(), isDense: true),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.person, size: 14),
                  label: const Text('Set ID', style: TextStyle(fontSize: 12)),
                  onPressed: _setCustomerUserId,
                ),
                const SizedBox(width: 4),
                OutlinedButton(
                  onPressed: _clearCustomerUserId,
                  child: const Text('Clear', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeepLinkCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('2. Simulate Deep Link & Campaign Intake', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            const Text('Parses ref, click_id, and UTM campaign parameters.', style: TextStyle(fontSize: 11, color: Colors.black54)),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'App URL / Universal Link', border: OutlineInputBorder(), isDense: true),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.link, size: 14),
                  label: const Text('Parse & Ingest Link', style: TextStyle(fontSize: 12)),
                  onPressed: _handleDeepLink,
                ),
                OutlinedButton(
                  child: const Text('Preset: ZetSim Promo', style: TextStyle(fontSize: 11)),
                  onPressed: () {
                    _urlController.text = 'https://zetsim.com/go?ref=AFF_ZETSIM&utm_campaign=summer_2026&utm_source=instagram&sub1=influencer_99';
                  },
                ),
                OutlinedButton(
                  child: const Text('Preset: No Ref', style: TextStyle(fontSize: 11)),
                  onPressed: () {
                    _urlController.text = 'https://zetsim.com/store/plans';
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInAppEventsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('3. Track Funnel Journey Events ("Upto where user went")', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            const Text('AppsFlyer style trackEvent(eventName, properties).', style: TextStyle(fontSize: 11, color: Colors.black54)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.public, size: 14),
                  label: const Text('View Destination (US)', style: TextStyle(fontSize: 11)),
                  onPressed: () => _trackFunnelEvent(EventNames.viewDestination, {
                    'country': 'United States',
                    'country_code': 'US',
                  }),
                ),
                ActionChip(
                  avatar: const Icon(Icons.sim_card, size: 14),
                  label: const Text('View Plan (USA 10GB)', style: TextStyle(fontSize: 11)),
                  onPressed: () => _trackFunnelEvent(EventNames.viewPlan),
                ),
                ActionChip(
                  avatar: const Icon(Icons.shopping_bag, size: 14),
                  label: const Text('Initiate Checkout', style: TextStyle(fontSize: 11)),
                  onPressed: () => _trackFunnelEvent(EventNames.initiateCheckout, {
                    'step': 'personal_info',
                    'plan_id': _planIdController.text.trim(),
                  }),
                ),
                ActionChip(
                  avatar: const Icon(Icons.credit_card, size: 14),
                  label: const Text('Add Payment Info', style: TextStyle(fontSize: 11)),
                  onPressed: () => _trackFunnelEvent(EventNames.addPaymentInfo, {
                    'method': 'stripe',
                  }),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReferralCodeCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('4. Set Referral Code / Coupon in App', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            const Text('Calls setReferralCode(code). Used on promo or sign-up screen.', style: TextStyle(fontSize: 11, color: Colors.black54)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _refCodeController,
                    decoration: const InputDecoration(labelText: 'Referral / Promo Code', border: OutlineInputBorder(), isDense: true),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.check, size: 14),
                  label: const Text('Set Code', style: TextStyle(fontSize: 12)),
                  onPressed: _setReferralCode,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('5. Track Conversion / Purchase with Plan Metadata', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            const Text('Reports order with purchased plan details & credits the affiliate.', style: TextStyle(fontSize: 11, color: Colors.black54)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _orderIdController,
                    decoration: const InputDecoration(labelText: 'Order ID', border: OutlineInputBorder(), isDense: true),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _amountController,
                    decoration: const InputDecoration(labelText: 'Amount', border: OutlineInputBorder(), isDense: true),
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _currencyController,
                    decoration: const InputDecoration(labelText: 'Currency', border: OutlineInputBorder(), isDense: true),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _planIdController,
                    decoration: const InputDecoration(labelText: 'Plan ID (Metadata)', border: OutlineInputBorder(), isDense: true),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _planNameController,
                    decoration: const InputDecoration(labelText: 'Plan Name', border: OutlineInputBorder(), isDense: true),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _countryCodeController,
                    decoration: const InputDecoration(labelText: 'Country', border: OutlineInputBorder(), isDense: true),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<ConversionEventType>(
                    initialValue: _eventType,
                    decoration: const InputDecoration(labelText: 'Event Type', border: OutlineInputBorder(), isDense: true),
                    items: ConversionEventType.values
                        .map((e) => DropdownMenuItem(value: e, child: Text(e.name, style: const TextStyle(fontSize: 12))))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _eventType = val);
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _couponOverrideController,
                    decoration: const InputDecoration(labelText: 'Coupon Override', border: OutlineInputBorder(), isDense: true),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.shopping_cart, size: 14),
                  label: const Text('Track Conversion', style: TextStyle(fontSize: 12)),
                  onPressed: _trackConversion,
                ),
                OutlinedButton(
                  child: const Text('Test Duplicate (409)', style: TextStyle(fontSize: 11)),
                  onPressed: () {
                    _orderIdController.text = 'duplicate-test';
                    _trackConversion();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueAndResetCard(AffiliateTracker? tracker) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.send, size: 14),
              label: const Text('Flush Queue', style: TextStyle(fontSize: 12)),
              onPressed: _flush,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline, size: 14, color: Colors.red),
              label: const Text('Clear Attribution', style: TextStyle(color: Colors.red, fontSize: 12)),
              onPressed: _clearAttribution,
            ),
          ],
        ),
      ),
    );
  }
}

class _MockTrackingHttpClient extends http.BaseClient {
  _MockTrackingHttpClient({required this.onPost});

  final http.Response Function(Uri url, Map<String, String> headers, String body) onPost;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request && request.method == 'POST') {
      final response = onPost(request.url, request.headers, request.body);
      return http.StreamedResponse(
        Stream.value(utf8.encode(response.body)),
        response.statusCode,
        headers: response.headers,
      );
    }
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 404);
  }
}
