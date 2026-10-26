/// Where the current attribution came from.
enum AttributionSource {
  /// The app was opened from an affiliate link (App Link, Universal Link or
  /// custom scheme) that carried a ref code.
  deepLink,

  /// Android only: the app was installed from a Google Play link whose
  /// `referrer` parameter carried a ref code.
  installReferrer,

  /// The user entered an affiliate's referral/coupon code in the app.
  referralCode,
}

/// The affiliate touch that conversions are credited to. Last touch wins: a
/// newer deep link or referral code replaces the previous attribution.
class Attribution {
  const Attribution._({
    required this.source,
    required this.capturedAt,
    this.refCode,
    this.clickId,
    this.referralCode,
    this.campaign,
    this.trafficSource,
    this.medium,
    this.channel,
    this.sub1,
    this.sub2,
    this.customParameters = const {},
  });

  /// A tracked click on an affiliate link.
  const Attribution.click({
    required String refCode,
    required String clickId,
    required AttributionSource source,
    required DateTime capturedAt,
    String? campaign,
    String? trafficSource,
    String? medium,
    String? channel,
    String? sub1,
    String? sub2,
    Map<String, String> customParameters = const {},
  }) : this._(
          refCode: refCode,
          clickId: clickId,
          source: source,
          capturedAt: capturedAt,
          campaign: campaign,
          trafficSource: trafficSource,
          medium: medium,
          channel: channel,
          sub1: sub1,
          sub2: sub2,
          customParameters: customParameters,
        );

  /// A referral code the user typed in. Resolved server-side against the
  /// affiliate's coupon code, so no click is recorded for it.
  const Attribution.referralCode({
    required String code,
    required DateTime capturedAt,
  }) : this._(
          referralCode: code,
          source: AttributionSource.referralCode,
          capturedAt: capturedAt,
        );

  /// The affiliate link's ref code. Null for [AttributionSource.referralCode].
  final String? refCode;

  /// The public click id recorded for this touch. Null for
  /// [AttributionSource.referralCode].
  final String? clickId;

  /// The code the user entered. Only set for [AttributionSource.referralCode].
  final String? referralCode;

  /// Campaign name (e.g. from utm_campaign, campaign).
  final String? campaign;

  /// Traffic source (e.g. from utm_source, source).
  final String? trafficSource;

  /// Marketing medium (e.g. from utm_medium, medium).
  final String? medium;

  /// Channel tag (e.g. from channel, af_channel).
  final String? channel;

  /// Sub-affiliate or custom tracking identifier 1.
  final String? sub1;

  /// Sub-affiliate or custom tracking identifier 2.
  final String? sub2;

  /// Any additional query parameters present on the touch.
  final Map<String, String> customParameters;

  final AttributionSource source;

  /// When the SDK captured this touch on the device.
  final DateTime capturedAt;

  bool get isClick => clickId != null;

  Map<String, Object?> toJson() => {
        'source': source.name,
        'captured_at': capturedAt.toUtc().toIso8601String(),
        if (refCode != null) 'ref_code': refCode,
        if (clickId != null) 'click_id': clickId,
        if (referralCode != null) 'referral_code': referralCode,
        if (campaign != null) 'campaign': campaign,
        if (trafficSource != null) 'traffic_source': trafficSource,
        if (medium != null) 'medium': medium,
        if (channel != null) 'channel': channel,
        if (sub1 != null) 'sub1': sub1,
        if (sub2 != null) 'sub2': sub2,
        if (customParameters.isNotEmpty) 'custom_parameters': customParameters,
      };

  /// Returns null for anything that does not look like a stored attribution,
  /// so a corrupt value is dropped instead of crashing the host app.
  static Attribution? fromJson(Object? json) {
    if (json is! Map) return null;
    final source = AttributionSource.values
        .where((s) => s.name == json['source'])
        .firstOrNull;
    final capturedAt = DateTime.tryParse('${json['captured_at']}');
    if (source == null || capturedAt == null) return null;

    if (source == AttributionSource.referralCode) {
      final code = json['referral_code'];
      if (code is! String || code.isEmpty) return null;
      return Attribution.referralCode(code: code, capturedAt: capturedAt);
    }
    final refCode = json['ref_code'];
    final clickId = json['click_id'];
    if (refCode is! String || clickId is! String) return null;

    Map<String, String> custom = {};
    if (json['custom_parameters'] is Map) {
      custom = (json['custom_parameters'] as Map).map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    }

    return Attribution.click(
      refCode: refCode,
      clickId: clickId,
      source: source,
      capturedAt: capturedAt,
      campaign: json['campaign'] as String?,
      trafficSource: json['traffic_source'] as String?,
      medium: json['medium'] as String?,
      channel: json['channel'] as String?,
      sub1: json['sub1'] as String?,
      sub2: json['sub2'] as String?,
      customParameters: custom,
    );
  }

  @override
  String toString() {
    if (!isClick) return 'Attribution(referralCode=$referralCode)';
    final parts = [
      source.name,
      'ref=$refCode',
      'click=$clickId',
      if (campaign != null) 'campaign=$campaign',
      if (trafficSource != null) 'source=$trafficSource',
    ];
    return 'Attribution(${parts.join(', ')})';
  }
}

/// Mirrors the backend's `ConversionEventType`.
enum ConversionEventType {
  sale('sale'),
  lead('lead'),
  renewal('renewal'),
  registration('registration'),
  appInstall('app_install');

  const ConversionEventType(this.wireName);

  /// The value the API expects in `event_type`.
  final String wireName;
}

enum ConversionStatus {
  /// The server accepted the conversion. It is `pending` until the merchant
  /// approves it in the dashboard.
  recorded,

  /// The server already has a conversion with this order id. Safe to ignore:
  /// order ids are the idempotency key.
  duplicate,

  /// Could not reach the server. The conversion is stored on the device and
  /// retried automatically, including after an app restart.
  queued,

  /// There is no affiliate attribution on this device, so nothing was sent.
  notAttributed,

  /// The server refused the conversion and it will not be retried, for
  /// example because the attribution window expired or the ref code is
  /// unknown. See [ConversionResult.message].
  rejected,
}

class ConversionResult {
  const ConversionResult(this.status, {this.conversionId, this.message});

  final ConversionStatus status;

  /// The backend's conversion id, when [status] is
  /// [ConversionStatus.recorded].
  final String? conversionId;

  /// Server error detail when [status] is [ConversionStatus.rejected].
  final String? message;

  @override
  String toString() => 'ConversionResult(${status.name}'
      '${conversionId != null ? ', id=$conversionId' : ''}'
      '${message != null ? ', $message' : ''})';
}

/// Delivery status for in-app funnel events.
enum EventStatus {
  /// The server accepted the event.
  recorded,

  /// Could not reach the server immediately; stored on device and queued for retry.
  queued,

  /// Server rejected the event.
  rejected,
}

/// Result returned from tracking an in-app funnel event.
class EventResult {
  const EventResult(this.status, {this.message});

  final EventStatus status;
  final String? message;

  @override
  String toString() => 'EventResult(${status.name}'
      '${message != null ? ', $message' : ''})';
}

/// Common standard event names matching industry attribution standards.
abstract final class EventNames {
  static const sessionStart = 'session_start';
  static const viewDestination = 'view_destination';
  static const viewPlan = 'view_plan';
  static const initiateCheckout = 'initiate_checkout';
  static const addPaymentInfo = 'add_payment_info';
  static const purchase = 'purchase';
  static const search = 'search';
}
