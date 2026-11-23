import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'config.dart';
import 'event_queue.dart';
import 'link_parser.dart';
import 'models.dart';
import 'platform.dart';
import 'storage.dart';
import 'uuid.dart';
import 'version.dart';

/// Affiliate attribution for a Flutter app.
///
/// ```dart
/// await AffiliateTracker.init(const AffiliateConfig(
///   apiBaseUrl: 'https://track.example.com',
///   trackingKey: 'your-program-tracking-key',
/// ));
///
/// // From your deep-link handler:
/// AffiliateTracker.instance.handleDeepLink(uri);
///
/// // When the purchase completes:
/// await AffiliateTracker.instance.trackConversion(
///   orderId: order.id, amount: order.total, currency: 'USD');
/// ```
class AffiliateTracker with WidgetsBindingObserver {
  AffiliateTracker._({
    required this.config,
    required KeyValueStore store,
    required http.Client client,
    required bool ownsClient,
    required InstallReferrerSource? installReferrer,
    required String? userAgent,
    required DateTime Function() now,
  })  : _store = store,
        _client = client,
        _ownsClient = ownsClient,
        _installReferrer = installReferrer,
        _now = now {
    _queue = EventQueue(
      store: store,
      api: TrackingApi(config: config, client: client, userAgent: userAgent),
      maxAge: config.maxEventAge,
      now: now,
      log: _log,
      onResult: _onResult,
    );
  }

  static const _attributionKey = 'attribution';
  static const _installIdKey = 'install_id';
  static const _installReferrerKey = 'install_referrer';
  static const _lastLinkKey = 'last_link';
  static const _customerUserIdKey = 'customer_user_id';

  /// Referrer lookups that fail transiently are retried on later launches,
  /// up to this many times.
  static const _maxReferrerAttempts = 5;

  /// Android re-delivers the launch intent when the app is reopened from
  /// recents, and link plugins often emit the initial link more than once.
  /// The same link inside this window is not counted as a new click.
  static const _sameLinkWindow = Duration(hours: 24);

  /// An app that was updated since it was installed may be an existing user
  /// getting the first version with the SDK. Their Play referrer is still
  /// readable, but it belongs to an install the SDK never saw, so it is only
  /// used when the install is at most this old.
  static const _recentInstall = Duration(days: 7);

  static AffiliateTracker? _instance;

  /// The tracker created by [init].
  static AffiliateTracker get instance {
    final tracker = _instance;
    if (tracker == null) {
      throw StateError('AffiliateTracker.init() has not been called');
    }
    return tracker;
  }

  static bool get isInitialized => _instance != null;

  final AffiliateConfig config;
  final KeyValueStore _store;
  final http.Client _client;
  final bool _ownsClient;
  final InstallReferrerSource? _installReferrer;
  final DateTime Function() _now;
  late final EventQueue _queue;

  Attribution? _attribution;
  String? _customerUserId;

  /// Bumped on every attribution change, so the install referrer can tell
  /// whether something newer happened while it was being looked up.
  int _attributionVersion = 0;
  ({String uri, DateTime at})? _lastLink;
  String _installId = '';
  Future<void> _referrerDone = Future.value();
  bool _observingLifecycle = false;
  bool _disposed = false;

  /// Every change to attribution state runs through this chain, one at a
  /// time. Without it a conversion could read an attribution whose click is
  /// not queued yet, and two deliveries of the same launch link could both
  /// pass the repeat check.
  Future<void> _lock = Future.value();

  /// Sets up the tracker and makes it available as [instance].
  ///
  /// Only reads local state before returning (a few milliseconds). Queued
  /// events are sent and the Android install referrer is read in the
  /// background; [trackConversion] waits for the referrer so a first-launch
  /// conversion is not missed.
  static Future<AffiliateTracker> init(AffiliateConfig config) async {
    WidgetsFlutterBinding.ensureInitialized();
    final useReferrer = config.readInstallReferrer &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android;
    return create(
      config: config,
      store: SharedPreferencesStore(),
      installReferrer: useReferrer ? const MethodChannelInstallReferrer() : null,
      userAgent: await buildUserAgent(sdkVersion),
      observeLifecycle: true,
    );
  }

  /// Like [init], with every dependency replaceable. Meant for tests and for
  /// apps that manage their own HTTP client or storage.
  static Future<AffiliateTracker> create({
    required AffiliateConfig config,
    KeyValueStore? store,
    http.Client? client,
    InstallReferrerSource? installReferrer,
    String? userAgent,
    DateTime Function()? now,
    bool observeLifecycle = false,
  }) async {
    final previous = _instance;
    if (previous != null) {
      previous.dispose();
      // Let a state change it was in the middle of finish before this one
      // reads the same storage.
      await previous._lock;
    }
    final tracker = AffiliateTracker._(
      config: config,
      store: store ?? MemoryStore(),
      client: client ?? http.Client(),
      ownsClient: client == null,
      installReferrer: installReferrer,
      userAgent: userAgent,
      now: now ?? DateTime.now,
    );
    await tracker._start(observeLifecycle: observeLifecycle);
    _instance = tracker;
    return tracker;
  }

  Future<void> _start({required bool observeLifecycle}) async {
    _attribution = Attribution.fromJson(await _readJson(_attributionKey));
    final lastLink = await _readJson(_lastLinkKey);
    if (lastLink is Map) {
      final at = DateTime.tryParse('${lastLink['at']}');
      if (lastLink['uri'] is String && at != null) {
        _lastLink = (uri: lastLink['uri'] as String, at: at);
      }
    }
    final storedInstallId = await _read(_installIdKey);
    if (storedInstallId == null) {
      _installId = uuidV4();
      await _write(_installIdKey, _installId);
    } else {
      _installId = storedInstallId;
    }
    _customerUserId = await _read(_customerUserIdKey);
    await _queue.load();

    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }

    unawaited(_queue.flush());
    _referrerDone = _checkInstallReferrer().catchError((Object e) {
      _log('Install referrer check failed: $e');
    });
  }

  /// The affiliate touch conversions are currently credited to, or null.
  /// On an Android first launch this can still change until [ready]
  /// completes.
  Attribution? get attribution => _attribution;

  /// Completes once the Android install referrer has been checked: at most
  /// about ten seconds after [init] on a first launch, and right away on
  /// every launch after that.
  Future<void> get ready => _referrerDone;

  /// Events stored on the device and not yet delivered.
  int get pendingEventCount => _queue.length;

  /// A random id for this installation, used as the `app_install` order id
  /// when the platform does not provide a stable install key.
  String get installId => _installId;

  /// The customer or user ID associated with this app install, or null if anonymous.
  String? get customerUserId => _customerUserId;

  /// Associates the current device session with a registered customer or user ID
  /// (e.g. email, phone, or backend account ID).
  ///
  /// Passing null or an empty string removes the association (e.g. on logout).
  Future<void> setCustomerUserId(String? userId) async {
    _checkNotDisposed();
    final trimmed = userId?.trim();
    await _serialized(() async {
      if (trimmed == null || trimmed.isEmpty) {
        _customerUserId = null;
        await _delete(_customerUserIdKey);
        _log('Cleared customer user ID');
      } else {
        _customerUserId = trimmed;
        await _write(_customerUserIdKey, trimmed);
        _log('Set customer user ID: $trimmed');
      }
    });
  }

  /// Call with every link that opens the app. Links without a ref code are
  /// ignored and return null, so it is safe to pass all of them.
  ///
  /// Records a click for the ref code and makes it the current attribution.
  /// Returns once that is stored; the click is delivered in the background.
  Future<Attribution?> handleDeepLink(Uri uri) async {
    _checkNotDisposed();
    final params = paramsFromUri(
      uri,
      refParams: config.refParams,
      clickIdParams: config.clickIdParams,
      campaignParams: config.campaignParams,
      sourceParams: config.sourceParams,
      mediumParams: config.mediumParams,
    );
    if (params == null) return null;

    return _serialized(() async {
      if (_disposed) return _attribution;
      final now = _now();
      final link = uri.toString();
      final last = _lastLink;
      if (last != null && last.uri == link && now.difference(last.at) < _sameLinkWindow) {
        _log('Ignoring repeat of $link');
        return _attribution;
      }
      _lastLink = (uri: link, at: now);

      final attribution = Attribution.click(
        refCode: params.refCode,
        clickId: params.clickId ?? uuidV4(),
        source: AttributionSource.deepLink,
        capturedAt: now,
        campaign: params.campaign,
        trafficSource: params.source,
        medium: params.medium,
        channel: params.channel,
        sub1: params.sub1,
        sub2: params.sub2,
        customParameters: params.customParams,
      );
      // Queue the click before exposing the attribution: a conversion that
      // names this click must never be queued ahead of it.
      await _enqueueClick(attribution, referer: _landingPage(uri));
      await _setAttribution(attribution);
      await _write(
        _lastLinkKey,
        jsonEncode({'uri': link, 'at': now.toUtc().toIso8601String()}),
      );
      _log('Captured $attribution from $link');
      unawaited(_queue.flush());
      return attribution;
    });
  }

  /// Attributes this user to the affiliate whose coupon code they entered,
  /// e.g. on a "Who referred you?" screen. Replaces any earlier attribution.
  ///
  /// The code is not checked here (the API has no lookup for it); an unknown
  /// code makes the next conversion come back [ConversionStatus.rejected].
  Future<void> setReferralCode(String code) async {
    _checkNotDisposed();
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(code, 'code', 'must not be empty');
    }
    // The backend upper-cases coupon codes before matching.
    await _serialized(() => _setAttribution(
          Attribution.referralCode(code: trimmed.toUpperCase(), capturedAt: _now()),
        ));
  }

  /// Forget the current attribution, e.g. after the user signs out.
  Future<void> clearAttribution() async {
    _checkNotDisposed();
    await _serialized(() async {
      await _setAttribution(null);
      _lastLink = null;
      await _delete(_lastLinkKey);
    });
  }

  /// Reports a conversion for the current attribution.
  ///
  /// [orderId] is the idempotency key: reporting the same id twice is safe
  /// and the second call returns [ConversionStatus.duplicate]. For
  /// non-purchase events use an id that is unique per event, such as
  /// `'signup:<userId>'`.
  ///
  /// A [couponCode] entered at checkout overrides the stored attribution for
  /// this conversion only.
  ///
  /// An optional [metadata] map can provide rich product details (e.g. plan ID,
  /// plan name, country code, data size) for the conversion report.
  ///
  /// When the device is offline the conversion is stored and retried, and
  /// the result is [ConversionStatus.queued].
  Future<ConversionResult> trackConversion({
    required String orderId,
    required num amount,
    String currency = 'USD',
    ConversionEventType eventType = ConversionEventType.sale,
    String? couponCode,
    Map<String, Object?>? metadata,
    bool? allowOrganic,
  }) async {
    _checkNotDisposed();
    final externalOrderId = orderId.trim();
    if (externalOrderId.isEmpty) {
      throw ArgumentError.value(orderId, 'orderId', 'must not be empty');
    }
    final normalizedCurrency = currency.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(normalizedCurrency)) {
      throw ArgumentError.value(currency, 'currency', 'must be an ISO 4217 code');
    }
    final formattedAmount = _formatAmount(amount);
    final coupon = couponCode?.trim();
    final shouldAllowOrganic = allowOrganic ?? config.trackOrganicConversions;

    await _referrerDone;

    final event = await _serialized(() async {
      if (_disposed) return null;
      final Map<String, Object?> attributionFields = {};
      if (coupon != null && coupon.isNotEmpty) {
        attributionFields['coupon_code'] = coupon.toUpperCase();
      } else if (_attribution?.clickId case final clickId?) {
        attributionFields['click_id'] = clickId;
      } else if (_attribution?.referralCode case final code?) {
        attributionFields['coupon_code'] = code;
      }
      if (attributionFields.isEmpty && !shouldAllowOrganic) {
        return null;
      }
      final event = PendingEvent(
        id: uuidV4(),
        kind: EventKind.conversion,
        createdAt: _now(),
        body: {
          ...attributionFields,
          'external_order_id': externalOrderId,
          'amount': formattedAmount,
          'currency': normalizedCurrency,
          'event_type': eventType.wireName,
          if (metadata != null && metadata.isNotEmpty) 'metadata': metadata,
          if (_customerUserId != null) 'customer_user_id': _customerUserId,
        },
      );
      await _queue.add(event);
      return event;
    });
    if (event == null) {
      _log('Conversion $externalOrderId not sent: no attribution');
      return const ConversionResult(ConversionStatus.notAttributed);
    }

    final results = await _queue.flush();
    return switch (results[event.id]) {
      Delivered(:final json) =>
        ConversionResult(ConversionStatus.recorded, conversionId: json['id'] as String?),
      Duplicate() => const ConversionResult(ConversionStatus.duplicate),
      Rejected(:final message) =>
        ConversionResult(ConversionStatus.rejected, message: message),
      Retry() || null => const ConversionResult(ConversionStatus.queued),
    };
  }

  /// Tracks an in-app funnel or milestone event (e.g. `view_plan`, `initiate_checkout`).
  ///
  /// Can be called even if the user has no affiliate attribution yet;
  /// if attribution exists, the current touch is linked automatically.
  Future<EventResult> trackEvent({
    required String eventName,
    Map<String, Object?>? properties,
  }) async {
    _checkNotDisposed();
    final trimmedName = eventName.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(eventName, 'eventName', 'must not be empty');
    }

    final event = await _serialized(() async {
      if (_disposed) return null;
      final Map<String, Object?> attributionFields = {};
      if (_attribution?.clickId case final clickId?) {
        attributionFields['click_id'] = clickId;
      }
      if (_attribution?.referralCode case final code?) {
        attributionFields['coupon_code'] = code;
      }

      final event = PendingEvent(
        id: uuidV4(),
        kind: EventKind.event,
        createdAt: _now(),
        body: {
          ...attributionFields,
          'event_name': trimmedName,
          if (properties != null && properties.isNotEmpty) 'properties': properties,
          if (_customerUserId != null) 'customer_user_id': _customerUserId,
        },
      );
      await _queue.add(event);
      return event;
    });

    if (event == null) {
      return const EventResult(EventStatus.rejected, message: 'Tracker disposed');
    }

    final results = await _queue.flush();
    return switch (results[event.id]) {
      Delivered() => const EventResult(EventStatus.recorded),
      Rejected(:final message) => EventResult(EventStatus.rejected, message: message),
      Duplicate() => const EventResult(EventStatus.recorded),
      Retry() || null => const EventResult(EventStatus.queued),
    };
  }

  /// Refunds cannot be reported from an app.
  ///
  /// The server only accepts a refund that carries the program's API secret
  /// (or an HMAC signed with it), so that nobody holding the public tracking
  /// key can void an affiliate's commission. An app cannot keep that secret,
  /// so report refunds from your own server instead: `POST
  /// /api/v1/t/refund` with the `X-API-Secret` header (the dashboard shows
  /// the request on the program's Tracking tab).
  ///
  /// This method sends nothing and always returns
  /// [ConversionStatus.rejected] with an explanation in
  /// [ConversionResult.message].
  @Deprecated('Report refunds from your server with the API secret; '
      'an app cannot hold it. This method sends nothing.')
  Future<ConversionResult> trackRefund({
    required String orderId,
    num? refundAmount,
    String? reason,
    List<Map<String, dynamic>>? items,
  }) async {
    _checkNotDisposed();
    _log('trackRefund($orderId) ignored: refunds must come from your server');
    return const ConversionResult(
      ConversionStatus.rejected,
      message: refundFromServerMessage,
    );
  }

  /// Why [trackRefund] does nothing.
  static const refundFromServerMessage =
      'Refunds must be reported from your server with the program API secret '
      '(POST /api/v1/t/refund with the X-API-Secret header), not from the app.';

  /// Sends queued events now. Also happens on start, on app resume and after
  /// every new event, so apps rarely need to call it.
  Future<void> flush() => _queue.flush();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_queue.flush());
  }

  /// Stops background work and releases the HTTP client. Queued events stay
  /// on the device for the next [init]. After this the tracker writes
  /// nothing, so it cannot overwrite the state of the one that replaces it.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    _queue.dispose();
    if (_ownsClient) _client.close();
    if (identical(_instance, this)) _instance = null;
  }

  Future<void> _checkInstallReferrer() async {
    final source = _installReferrer;
    if (source == null) return;
    final state = await _read(_installReferrerKey);
    if (state == 'done') return;
    final startedAt = _now();
    final versionAtStart = _attributionVersion;

    final InstallReferrerDetails? details;
    try {
      details = await source.fetch().timeout(const Duration(seconds: 10));
    } on Object catch (e) {
      final permanent = e is InstallReferrerException && e.permanent;
      final attempts = (int.tryParse(state ?? '') ?? 0) + 1;
      final giveUp = permanent || attempts >= _maxReferrerAttempts;
      await _write(_installReferrerKey, giveUp ? 'done' : '$attempts');
      _log('Install referrer unavailable ($e)${giveUp ? '' : ', will retry next launch'}');
      return;
    }
    if (_disposed) return;

    final params = details == null
        ? null
        : paramsFromReferrer(
            details.referrer,
            refParams: config.refParams,
            clickIdParams: config.clickIdParams,
            campaignParams: config.campaignParams,
            sourceParams: config.sourceParams,
            mediumParams: config.mediumParams,
          );
    if (details == null || params == null) {
      _log('Install is not from an affiliate link (referrer: ${details?.referrer})');
      await _write(_installReferrerKey, 'done');
      return;
    }
    final InstallReferrerDetails found = details;
    final stale = _staleInstall(found);
    if (stale != null) {
      _log('Ignoring install referrer: $stale');
      await _write(_installReferrerKey, 'done');
      return;
    }

    await _serialized(() async {
      if (_disposed) return;
      final touchedAt = found.clickTime ?? startedAt;
      final attribution = Attribution.click(
        refCode: params.refCode,
        // The install key keeps the click id stable if this runs again after
        // a crash or a data clear, so the server dedupes the click.
        clickId: params.clickId ?? found.installKey ?? uuidV4(),
        source: AttributionSource.installReferrer,
        capturedAt: touchedAt,
        campaign: params.campaign,
        trafficSource: params.source,
        medium: params.medium,
        channel: params.channel,
        sub1: params.sub1,
        sub2: params.sub2,
        customParameters: params.customParams,
      );
      await _enqueueClick(attribution, referer: 'https://play.google.com/store');

      // Last touch wins. A link or code handled while the referrer was being
      // read is newer than the Play Store click, and so is any stored
      // attribution captured after that click.
      final current = _attribution;
      if (_attributionVersion == versionAtStart &&
          (current == null || current.capturedAt.isBefore(touchedAt))) {
        await _setAttribution(attribution);
      }
      if (config.reportInstalls) {
        await _queue.add(PendingEvent(
          id: uuidV4(),
          kind: EventKind.conversion,
          createdAt: _now(),
          body: {
            'click_id': attribution.clickId,
            'external_order_id': 'app_install:${found.installKey ?? _installId}',
            'amount': '0',
            'currency': 'USD',
            'event_type': ConversionEventType.appInstall.wireName,
            if (_customerUserId != null) 'customer_user_id': _customerUserId,
          },
        ));
      }
      // Written last: if anything above did not happen, the next launch
      // reads the referrer again, and the stable ids make that harmless.
      await _write(_installReferrerKey, 'done');
      _log('Captured $attribution from install referrer');
    });
    unawaited(_queue.flush());
  }

  /// Why this referrer belongs to an install from before the running app
  /// version, or null if it can be used.
  String? _staleInstall(InstallReferrerDetails details) {
    final installed = details.firstInstallTime;
    final updated = details.lastUpdateTime;
    if (installed == null || updated == null) return null;
    // Never updated: the running build is the installed one, and it has the
    // SDK, so this is the install's first launch (or storage was cleared).
    if (!updated.isAfter(installed)) return null;
    if (_now().difference(installed) <= _recentInstall) return null;
    return 'installed ${installed.toIso8601String()} and updated since';
  }

  Future<void> _enqueueClick(Attribution attribution, {String? referer}) {
    return _queue.add(PendingEvent(
      id: uuidV4(),
      kind: EventKind.click,
      createdAt: _now(),
      body: {
        'ref_code': attribution.refCode,
        'click_id': attribution.clickId,
      },
      referer: referer,
    ));
  }

  Future<void> _onResult(PendingEvent event, SendResult result) async {
    switch (result) {
      case Delivered():
        _log('${event.kind.name} ${event.id} delivered');
      case Duplicate():
        _log('Conversion ${event.body['external_order_id']} was already recorded');
      case Rejected(:final statusCode, :final message):
        developer.log(
          '${event.kind.name} rejected with HTTP $statusCode: $message',
          name: 'affiliate_tracking',
          level: 900,
        );
        // A rejected click was never recorded, and 404/410 on a conversion
        // means the click or code is unknown or out of its window. Either
        // way every later conversion would fail the same way.
        final dead = event.kind == EventKind.click ||
            (event.kind == EventKind.conversion && (statusCode == 404 || statusCode == 410));
        if (!dead) return;
        await _serialized(() async {
          final current = _attribution;
          final sameTouch = (event.clickId != null && event.clickId == current?.clickId) ||
              (event.body['coupon_code'] != null &&
                  event.body['coupon_code'] == current?.referralCode);
          if (sameTouch) await _setAttribution(null);
        });
      case Retry():
        break; // The queue keeps retried events and does not report them.
    }
  }

  /// Runs [body] after every earlier state change has finished.
  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _lock.then((_) => body());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('This AffiliateTracker was disposed; use AffiliateTracker.instance');
    }
  }

  Future<void> _setAttribution(Attribution? attribution) async {
    if (_disposed) return;
    _attribution = attribution;
    _attributionVersion++;
    if (attribution == null) {
      await _delete(_attributionKey);
    } else {
      await _write(_attributionKey, jsonEncode(attribution.toJson()));
    }
  }

  // Storage helpers. A storage failure is logged, never thrown: the state in
  // memory stays right for this session. After dispose they do nothing.

  Future<String?> _read(String key) async {
    try {
      return await _store.read(key);
    } on Object catch (e) {
      _log('Could not read $key: $e');
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    if (_disposed) return;
    try {
      await _store.write(key, value);
    } on Object catch (e) {
      _log('Could not save $key: $e');
    }
  }

  Future<void> _delete(String key) async {
    if (_disposed) return;
    try {
      await _store.delete(key);
    } on Object catch (e) {
      _log('Could not delete $key: $e');
    }
  }

  Future<Object?> _readJson(String key) async {
    final raw = await _read(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      await _delete(key);
      return null;
    }
  }

  /// Where the link pointed, without its query, stored as the click's
  /// referrer. Apps are not told which app or page the link was tapped in.
  static String? _landingPage(Uri uri) {
    if (!uri.hasScheme) return null;
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }

  /// Sent as a string so the backend's Decimal gets exactly what was passed.
  static String _formatAmount(num amount) {
    if (!amount.isFinite || amount < 0) {
      throw ArgumentError.value(amount, 'amount', 'must be a finite number >= 0');
    }
    return amount.toString();
  }

  void _log(String message) {
    if (config.debug) developer.log(message, name: 'affiliate_tracking');
  }
}
