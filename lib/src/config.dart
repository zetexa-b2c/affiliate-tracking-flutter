class AffiliateConfig {
  const AffiliateConfig({
    required this.apiBaseUrl,
    required this.trackingKey,
    this.refParams = const ['ref', 'aff', 'referral', 'ref_code', 'affiliate'],
    this.clickIdParams = const ['click_id', 'aff_click_id'],
    this.campaignParams = const ['utm_campaign', 'campaign', 'cmp'],
    this.sourceParams = const ['utm_source', 'source', 'src'],
    this.mediumParams = const ['utm_medium', 'medium', 'med'],
    this.readInstallReferrer = true,
    this.reportInstalls = true,
    this.maxEventAge = const Duration(days: 30),
    this.requestTimeout = const Duration(seconds: 15),
    this.trackOrganicConversions = false,
    this.debug = false,
  });

  /// Origin of the affiliate platform API, e.g. `https://track.example.com`.
  /// The SDK calls `/api/v1/t/click`, `/api/v1/t/conversion`, and `/api/v1/t/event` under it.
  final String apiBaseUrl;

  /// The program's public tracking key (Admin → Program → Tracking). It is
  /// the same key the web snippet uses and is not a secret.
  final String trackingKey;

  /// Query parameters that carry the affiliate ref code, checked in order.
  /// `ref` matches the links the affiliate portal hands out.
  final List<String> refParams;

  /// Query parameters that may carry an existing click id. When the web
  /// snippet already recorded the click (e.g. on a landing page with a
  /// "Get the app" button), passing its id through keeps it one click.
  final List<String> clickIdParams;

  /// Query parameters that carry the campaign name.
  final List<String> campaignParams;

  /// Query parameters that carry the traffic source.
  final List<String> sourceParams;

  /// Query parameters that carry the marketing medium.
  final List<String> mediumParams;

  /// Android: read the Google Play Install Referrer on first launch so that
  /// installs from affiliate Play Store links are attributed.
  final bool readInstallReferrer;

  /// Report an `app_install` conversion (amount 0) when an install is
  /// attributed through the Play Install Referrer. Conversions stay pending
  /// until approved, but a program on flat commission pays the flat amount
  /// for each approved install, so turn this off if installs should not pay.
  final bool reportInstalls;

  /// Queued events older than this are dropped instead of retried. The
  /// server rejects conversions outside the attribution window anyway.
  final Duration maxEventAge;

  final Duration requestTimeout;

  /// Log SDK activity through `dart:developer` under the name
  /// `affiliate_tracking`.
  final bool debug;

  /// Whether to record direct / organic order conversions even when no
  /// affiliate link or coupon was used. Defaults to false.
  final bool trackOrganicConversions;

  Uri get clickEndpoint => _endpoint('api/v1/t/click');
  Uri get conversionEndpoint => _endpoint('api/v1/t/conversion');
  Uri get eventEndpoint => _endpoint('api/v1/t/event');
  Uri get refundEndpoint => _endpoint('api/v1/t/refund');

  Uri _endpoint(String path) {
    final base = apiBaseUrl.endsWith('/') ? apiBaseUrl : '$apiBaseUrl/';
    return Uri.parse(base).resolve(path);
  }
}
