import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the Play Install Referrer API reports for this install.
class InstallReferrerDetails {
  const InstallReferrerDetails({
    required this.referrer,
    this.clickTime,
    this.installBeginTime,
    this.firstInstallTime,
    this.lastUpdateTime,
    this.installKey,
  });

  /// The decoded `referrer` parameter of the Play Store URL.
  final String referrer;

  /// When the user clicked the Play Store link (server-reported by Play).
  final DateTime? clickTime;
  final DateTime? installBeginTime;

  /// From the package manager. When the app has been updated since it was
  /// installed, the install may predate the app version that has the SDK.
  final DateTime? firstInstallTime;
  final DateTime? lastUpdateTime;

  /// A UUID derived from the referrer and install times: the same on every
  /// read for one install (also after "Clear storage"), different after a
  /// reinstall.
  final String? installKey;
}

class InstallReferrerException implements Exception {
  const InstallReferrerException(this.code, {required this.permanent});

  /// The native response code, e.g. `SERVICE_UNAVAILABLE`.
  final String code;

  /// True when asking again on a later launch cannot succeed (the Play
  /// Store is missing or too old, or the API is not supported).
  final bool permanent;

  @override
  String toString() => 'InstallReferrerException($code)';
}

abstract interface class InstallReferrerSource {
  Future<InstallReferrerDetails?> fetch();
}

const _channel = MethodChannel('affiliate_tracking');

class MethodChannelInstallReferrer implements InstallReferrerSource {
  const MethodChannelInstallReferrer();

  static const _permanentCodes = {
    'FEATURE_NOT_SUPPORTED',
    'DEVELOPER_ERROR',
    'PERMISSION_ERROR',
  };

  @override
  Future<InstallReferrerDetails?> fetch() async {
    final Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<Object?, Object?>('getInstallReferrer');
    } on PlatformException catch (e) {
      throw InstallReferrerException(
        e.code,
        permanent: _permanentCodes.contains(e.code),
      );
    } on MissingPluginException {
      throw const InstallReferrerException('MISSING_PLUGIN', permanent: true);
    }
    final referrer = result?['referrer'];
    if (referrer is! String || referrer.isEmpty) return null;
    final installKey = result?['installKey'];
    return InstallReferrerDetails(
      referrer: referrer,
      clickTime: _fromMillis(result?['clickTimestampSeconds'], 1000),
      installBeginTime: _fromMillis(result?['installBeginTimestampSeconds'], 1000),
      firstInstallTime: _fromMillis(result?['firstInstallTimeMillis'], 1),
      lastUpdateTime: _fromMillis(result?['lastUpdateTimeMillis'], 1),
      installKey: installKey is String && installKey.isNotEmpty ? installKey : null,
    );
  }

  static DateTime? _fromMillis(Object? value, int scale) {
    if (value is! int || value <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(value * scale, isUtc: true);
  }
}

/// Builds the User-Agent the SDK sends. The backend derives the click's
/// `os` and `device_type` from it, so it follows the shape its parser
/// understands and ends with the SDK token, which the backend reports as
/// an app rather than a browser. Returns null where a User-Agent cannot or
/// should not be set (web, desktop).
Future<String?> buildUserAgent(String sdkVersion) async {
  if (kIsWeb) return null;
  final token = 'affiliate_tracking/$sdkVersion';
  final tablet = _isTablet();
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      String? release;
      try {
        final info = await _channel.invokeMapMethod<String, Object?>('getPlatformInfo');
        release = info?['osVersion'] as String?;
      } on PlatformException {
        release = null;
      } on MissingPluginException {
        release = null;
      }
      final os = release == null || release.isEmpty ? 'Android' : 'Android $release';
      return tablet
          ? 'Mozilla/5.0 (Linux; $os; Tablet) $token'
          : 'Mozilla/5.0 (Linux; $os) Mobile $token';
    case TargetPlatform.iOS:
      return tablet
          ? 'Mozilla/5.0 (iPad; CPU OS like Mac OS X) $token'
          : 'Mozilla/5.0 (iPhone; CPU iPhone OS like Mac OS X) $token';
    default:
      return null;
  }
}

/// The usual Material breakpoint: shortest side of 600 logical pixels.
/// Uses the display rather than the view, because the view has no size yet
/// when the SDK is initialised before `runApp`.
bool _isTablet() {
  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) return false;
  final display = views.first.display;
  if (display.devicePixelRatio <= 0) return false;
  return (display.size / display.devicePixelRatio).shortestSide >= 600;
}
