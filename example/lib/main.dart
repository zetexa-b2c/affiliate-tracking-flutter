import 'dart:async';

import 'package:affiliate_tracking/affiliate_tracking.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

// flutter run \
//   --dart-define=AFFILIATE_API=http://10.0.2.2:8035 \
//   --dart-define=AFFILIATE_TRACKING_KEY=<program tracking key>
const _apiBaseUrl = String.fromEnvironment(
  'AFFILIATE_API',
  defaultValue: 'http://10.0.2.2:8035', // host machine, from the Android emulator
);
const _trackingKey = String.fromEnvironment('AFFILIATE_TRACKING_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AffiliateTracker.init(const AffiliateConfig(
    apiBaseUrl: _apiBaseUrl,
    trackingKey: _trackingKey,
    debug: true,
  ));
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Affiliate tracking demo',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final _tracker = AffiliateTracker.instance;
  final _links = AppLinks();
  final _refController = TextEditingController();
  final _codeController = TextEditingController();
  final _log = <String>[];
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    // uriLinkStream also emits the link that launched the app.
    _linkSub = _links.uriLinkStream.listen(_onLink);
    _tracker.ready.then((_) => _refresh('Install referrer checked'));
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _refController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _onLink(Uri uri) async {
    final attribution = await _tracker.handleDeepLink(uri);
    _refresh(attribution == null ? 'Link without ref: $uri' : 'Link: $attribution');
  }

  Future<void> _simulateLink() async {
    final ref = _refController.text.trim();
    if (ref.isEmpty) return;
    await _onLink(Uri.parse('https://shop.example.com/app?ref=${Uri.encodeQueryComponent(ref)}'));
  }

  Future<void> _applyCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    await _tracker.setReferralCode(code);
    _refresh('Referral code set');
  }

  Future<void> _buy() async {
    final orderId = 'demo-${DateTime.now().millisecondsSinceEpoch}';
    final result = await _tracker.trackConversion(
      orderId: orderId,
      amount: 49.99,
      currency: 'USD',
    );
    _refresh('$orderId → $result');
  }

  Future<void> _flush() async {
    await _tracker.flush();
    _refresh('Flushed');
  }

  void _refresh(String message) {
    if (!mounted) return;
    setState(() => _log.insert(0, message));
  }

  @override
  Widget build(BuildContext context) {
    final attribution = _tracker.attribution;
    return Scaffold(
      appBar: AppBar(title: const Text('Affiliate tracking demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_trackingKey.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('No tracking key: run with '
                    '--dart-define=AFFILIATE_TRACKING_KEY=<key>'),
              ),
            ),
          Text('API: $_apiBaseUrl'),
          Text('Attribution: ${attribution ?? 'none'}'),
          Text('Pending events: ${_tracker.pendingEventCount}'),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _refController,
                decoration: const InputDecoration(labelText: 'Ref code (simulate link)'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _simulateLink, child: const Text('Open')),
          ]),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _codeController,
                decoration: const InputDecoration(labelText: 'Referral / coupon code'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _applyCode, child: const Text('Apply')),
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 8, children: [
            FilledButton.icon(
              onPressed: _buy,
              icon: const Icon(Icons.shopping_cart),
              label: const Text('Buy for \$49.99'),
            ),
            OutlinedButton(onPressed: _flush, child: const Text('Flush queue')),
            OutlinedButton(
              onPressed: () async {
                await _tracker.clearAttribution();
                _refresh('Attribution cleared');
              },
              child: const Text('Clear attribution'),
            ),
          ]),
          const Divider(height: 32),
          for (final line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
