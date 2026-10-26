import 'uuid.dart';

/// The affiliate parameters found in a link or install referrer.
class AffiliateParams {
  const AffiliateParams({
    required this.refCode,
    this.clickId,
    this.campaign,
    this.source,
    this.medium,
    this.channel,
    this.sub1,
    this.sub2,
    this.customParams = const {},
  });

  final String refCode;

  /// A click id carried through from a click the web snippet already
  /// recorded. Only accepted when it is a well-formed UUID, since the API
  /// rejects anything else.
  final String? clickId;

  /// Campaign name (e.g. utm_campaign, campaign).
  final String? campaign;

  /// Traffic source (e.g. utm_source, source).
  final String? source;

  /// Marketing medium (e.g. utm_medium, medium).
  final String? medium;

  /// Traffic channel (e.g. channel, af_channel).
  final String? channel;

  /// Sub-affiliate or custom tracking identifier 1.
  final String? sub1;

  /// Sub-affiliate or custom tracking identifier 2.
  final String? sub2;

  /// Any additional query parameters present on the link.
  final Map<String, String> customParams;
}

/// Pulls the ref code (and optional click id and campaign tags) out of a deep link's query.
AffiliateParams? paramsFromUri(
  Uri uri, {
  required List<String> refParams,
  required List<String> clickIdParams,
  List<String> campaignParams = const ['utm_campaign', 'campaign', 'cmp'],
  List<String> sourceParams = const ['utm_source', 'source', 'src'],
  List<String> mediumParams = const ['utm_medium', 'medium', 'med'],
}) {
  final Map<String, String> query;
  try {
    query = uri.queryParameters;
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
  return _fromQuery(
    query,
    refParams,
    clickIdParams,
    campaignParams: campaignParams,
    sourceParams: sourceParams,
    mediumParams: mediumParams,
  );
}

/// Parses a Google Play install referrer string, which is the decoded value
/// of the Play Store URL's `referrer` parameter, e.g.
/// `ref=Ab3dE_f9&click_id=...`. Organic installs report something like
/// `utm_source=google-play&utm_medium=organic` and yield null.
AffiliateParams? paramsFromReferrer(
  String referrer, {
  required List<String> refParams,
  required List<String> clickIdParams,
  List<String> campaignParams = const ['utm_campaign', 'campaign', 'cmp'],
  List<String> sourceParams = const ['utm_source', 'source', 'src'],
  List<String> mediumParams = const ['utm_medium', 'medium', 'med'],
}) {
  var raw = referrer.trim();
  // Links built with a double-encoded referrer arrive still encoded once.
  if (!raw.contains('=') && raw.contains('%3D')) {
    try {
      raw = Uri.decodeComponent(raw);
    } on ArgumentError {
      return null;
    }
  }
  final Map<String, String> query;
  try {
    query = Uri.splitQueryString(raw);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
  return _fromQuery(
    query,
    refParams,
    clickIdParams,
    campaignParams: campaignParams,
    sourceParams: sourceParams,
    mediumParams: mediumParams,
  );
}

AffiliateParams? _fromQuery(
  Map<String, String> query,
  List<String> refParams,
  List<String> clickIdParams, {
  List<String> campaignParams = const ['utm_campaign', 'campaign', 'cmp'],
  List<String> sourceParams = const ['utm_source', 'source', 'src'],
  List<String> mediumParams = const ['utm_medium', 'medium', 'med'],
}) {
  final refCode = _firstNonEmpty(query, refParams);
  if (refCode == null) return null;
  final clickId = _firstNonEmpty(query, clickIdParams);
  final campaign = _firstNonEmpty(query, campaignParams);
  final source = _firstNonEmpty(query, sourceParams);
  final medium = _firstNonEmpty(query, mediumParams);
  final channel = _firstNonEmpty(query, const ['channel', 'af_channel']);
  final sub1 = _firstNonEmpty(query, const ['sub1', 'sub_id', 'sub_id_1']);
  final sub2 = _firstNonEmpty(query, const ['sub2', 'sub_id_2']);

  final custom = Map<String, String>.from(query)
    ..removeWhere((k, _) =>
        refParams.contains(k) ||
        clickIdParams.contains(k) ||
        campaignParams.contains(k) ||
        sourceParams.contains(k) ||
        mediumParams.contains(k) ||
        const ['channel', 'af_channel', 'sub1', 'sub_id', 'sub_id_1', 'sub2', 'sub_id_2'].contains(k));

  return AffiliateParams(
    refCode: refCode,
    clickId: clickId != null && isUuid(clickId) ? clickId.toLowerCase() : null,
    campaign: campaign,
    source: source,
    medium: medium,
    channel: channel,
    sub1: sub1,
    sub2: sub2,
    customParams: custom,
  );
}

String? _firstNonEmpty(Map<String, String> query, List<String> keys) {
  for (final key in keys) {
    final value = query[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}
