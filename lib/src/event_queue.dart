import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'api.dart';
import 'storage.dart';

typedef EventResultCallback = FutureOr<void> Function(
  PendingEvent event,
  SendResult result,
);

/// A persistent FIFO of events, delivered one at a time in order.
///
/// Order matters: a conversion names its click by `click_id`, and the server
/// answers 404 for a click it has not seen yet. So when the head of the
/// queue cannot be delivered, delivery stops there rather than skipping
/// ahead, and resumes from the same event on the next flush.
class EventQueue {
  EventQueue({
    required this.store,
    required this.api,
    required this.maxAge,
    required this.now,
    required this.log,
    this.onResult,
    this.maxLength = 500,
  });

  static const storageKey = 'queue';

  final KeyValueStore store;
  final TrackingApi api;
  final Duration maxAge;
  final DateTime Function() now;
  final void Function(String message) log;
  final EventResultCallback? onResult;

  /// Oldest events are dropped beyond this, so a device that is offline for
  /// weeks cannot grow the queue without bound.
  final int maxLength;

  final List<PendingEvent> _events = [];
  Future<Map<String, SendResult>>? _running;
  bool _flushAgain = false;
  Timer? _retryTimer;
  int _consecutiveFailures = 0;
  bool _disposed = false;

  int get length => _events.length;

  List<PendingEvent> get events => List.unmodifiable(_events);

  Future<void> load() async {
    final String? raw;
    try {
      raw = await store.read(storageKey);
    } on Object catch (e) {
      log('Could not read the event queue: $e');
      return;
    }
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _events.addAll(decoded.map(PendingEvent.fromJson).whereType<PendingEvent>());
      }
    } on FormatException {
      log('Discarding unreadable event queue');
      await _persist();
    }
  }

  Future<void> add(PendingEvent event) async {
    if (_disposed) return;
    _events.add(event);
    while (_events.length > maxLength) {
      final dropped = _events.removeAt(0);
      log('Queue full, dropped ${dropped.kind.name} ${dropped.id}');
    }
    await _persist();
  }

  /// Delivers queued events in order until the queue is empty or an event
  /// needs a retry. Returns the outcome of every event that left the queue.
  ///
  /// Concurrent calls share one run; an event added during a run is picked
  /// up by that run.
  Future<Map<String, SendResult>> flush() {
    if (_disposed) return Future.value(const {});
    final running = _running;
    if (running != null) {
      _flushAgain = true;
      return running;
    }
    _retryTimer?.cancel();
    final run = _run().whenComplete(() => _running = null);
    _running = run;
    return run;
  }

  Future<Map<String, SendResult>> _run() async {
    final results = <String, SendResult>{};
    do {
      _flushAgain = false;
      while (_events.isNotEmpty && !_disposed) {
        final event = _events.first;
        if (now().difference(event.createdAt) > maxAge) {
          log('Dropping ${event.kind.name} ${event.id}: older than $maxAge');
          _events.removeAt(0);
          await _persist();
          continue;
        }

        final result = await api.send(event);
        if (_disposed) return results;
        if (result is Retry) {
          _consecutiveFailures++;
          log('${event.kind.name} ${event.id} not delivered (${result.reason}); '
              '${_events.length} event(s) waiting');
          _scheduleRetry();
          return results;
        }

        _consecutiveFailures = 0;
        _events.remove(event);
        await _persist();
        results[event.id] = result;
        try {
          await onResult?.call(event, result);
        } on Object catch (e) {
          log('Handling the result of ${event.id} failed: $e');
        }
      }
    } while (_flushAgain && !_disposed);
    return results;
  }

  /// Backs off 5s, 10s, 20s… up to 15 minutes while the app stays open.
  /// App start, resume and every new event also trigger a flush, so this
  /// only matters for long sessions with a flaky connection.
  void _scheduleRetry() {
    if (_disposed) return;
    final seconds = min(5 * pow(2, min(_consecutiveFailures - 1, 10)), 900);
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds.toInt()), () => flush());
  }

  /// Never throws: a storage failure leaves the queue correct in memory and
  /// is retried with the next change. After [dispose] it writes nothing, so a
  /// replaced tracker cannot overwrite its successor's queue.
  Future<void> _persist() async {
    if (_disposed) return;
    try {
      if (_events.isEmpty) {
        await store.delete(storageKey);
      } else {
        await store.write(storageKey, jsonEncode(_events.map((e) => e.toJson()).toList()));
      }
    } on Object catch (e) {
      log('Could not save the event queue: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
  }
}
