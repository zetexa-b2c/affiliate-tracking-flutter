import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import 'config.dart';

enum EventKind { click, conversion, event, refund }

/// A click, conversion or funnel event waiting to be delivered. The body is what gets
/// posted, minus `tracking_key`, which is added at send time so a rotated
/// key in a new app build applies to events queued by the old one.
class PendingEvent {
  PendingEvent({
    required this.id,
    required this.kind,
    required this.body,
    required this.createdAt,
    this.referer,
  });

  final String id;
  final EventKind kind;
  final Map<String, Object?> body;
  final DateTime createdAt;

  /// Sent as the `Referer` header on clicks; the backend stores it on the
  /// click row.
  final String? referer;

  String? get clickId => body['click_id'] as String?;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'body': body,
        'created_at': createdAt.toUtc().toIso8601String(),
        if (referer != null) 'referer': referer,
      };

  static PendingEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = EventKind.values.where((k) => k.name == json['kind']).firstOrNull;
    final createdAt = DateTime.tryParse('${json['created_at']}');
    final body = json['body'];
    final id = json['id'];
    if (kind == null || createdAt == null || body is! Map || id is! String) {
      return null;
    }
    return PendingEvent(
      id: id,
      kind: kind,
      body: Map<String, Object?>.from(body),
      createdAt: createdAt,
      referer: json['referer'] as String?,
    );
  }
}

sealed class SendResult {
  const SendResult();
}

class Delivered extends SendResult {
  const Delivered(this.json);
  final Map<String, Object?> json;
}

/// HTTP 409 on a conversion: this order id is already recorded.
class Duplicate extends SendResult {
  const Duplicate();
}

/// The server refused the event; retrying would get the same answer.
class Rejected extends SendResult {
  const Rejected(this.statusCode, this.message);
  final int statusCode;
  final String message;
}

/// Network failure, timeout, 408/425/429, 5xx, or a response that is not
/// about the event (see [TrackingApi.classify]). Keep the event and retry.
class Retry extends SendResult {
  const Retry(this.reason);
  final String reason;
}

class TrackingApi {
  TrackingApi({required this.config, required this.client, this.userAgent});

  final AffiliateConfig config;
  final http.Client client;
  final String? userAgent;

  Future<SendResult> send(PendingEvent event) async {
    final uri = switch (event.kind) {
      EventKind.click => config.clickEndpoint,
      EventKind.conversion => config.conversionEndpoint,
      EventKind.event => config.eventEndpoint,
      EventKind.refund => config.refundEndpoint,
    };
    final headers = {
      'content-type': 'application/json',
      'accept': 'application/json',
      if (userAgent != null) 'user-agent': userAgent!,
      if (event.referer != null) 'referer': event.referer!,
    };
    final body = jsonEncode({'tracking_key': config.trackingKey, ...event.body});

    final http.Response response;
    try {
      response = await client
          .post(uri, headers: headers, body: body)
          .timeout(config.requestTimeout);
    } on TimeoutException {
      return const Retry('timed out');
    } on Object catch (e) {
      // Socket/DNS/TLS failures arrive as http.ClientException; a blocked
      // cleartext http:// URL is a StateError. None of them are about the
      // event, so keep it and retry.
      return Retry('$e');
    }
    final result = classify(event.kind, response.statusCode, response.body);
    if (result is Retry && result.reason.contains('tracking_key')) {
      developer.log(
        '${result.reason}. Check AffiliateConfig.trackingKey and apiBaseUrl.',
        name: 'affiliate_tracking',
        level: 900,
      );
    }
    return result;
  }

  /// Only a FastAPI error about this particular event is final. A redirect,
  /// a proxy or firewall page, a missing route or an unknown tracking key is
  /// about the deployment or the app's config, can be fixed without shipping
  /// a new build, and is retried until `maxEventAge`.
  static SendResult classify(EventKind kind, int status, String body) {
    if (status >= 200 && status < 300) {
      return Delivered(_decodeObject(body));
    }
    if (status == 409 && kind == EventKind.conversion) return const Duplicate();
    final detail = _detail(body);
    final eventError = status >= 400 &&
        status < 500 &&
        !const {408, 425, 429}.contains(status) &&
        detail != null &&
        detail != 'Not Found' &&
        !detail.contains('tracking_key');
    if (eventError) return Rejected(status, detail);
    return Retry(detail == null ? 'HTTP $status' : 'HTTP $status: $detail');
  }

  static Map<String, Object?> _decodeObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } on FormatException {
      // Fall through: a 2xx with an unexpected body still counts as delivered.
    }
    return const {};
  }

  /// FastAPI puts a string in `detail` for HTTPException and a list of
  /// field errors for request validation (422).
  static String? _detail(String body) {
    final detail = _decodeObject(body)['detail'];
    if (detail is String) return detail;
    if (detail is List && detail.isNotEmpty) {
      return detail
          .map((e) => e is Map ? '${e['loc']}: ${e['msg']}' : '$e')
          .join('; ');
    }
    return null;
  }
}
