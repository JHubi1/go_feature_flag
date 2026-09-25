import 'dart:async';

import 'package:logging/logging.dart';

import 'relay_proxy_api.dart';

/// Buffers `FeatureEvent`/`TrackingEvent` objects and periodically flushes them
/// to the relay-proxy data collector endpoint.
///
/// Mirrors the Go SDK's `manager.DataCollectorManager`.
class DataCollectorManager {
  DataCollectorManager({
    required this.api,
    required this.maxEventStored,
    required this.collectInterval,
    required this.exporterMetadata,
    this.logger,
  });

  /// The low-level client used to flush buffered events.
  final RelayProxyApi api;

  /// Maximum number of buffered events before an early flush is triggered.
  final int maxEventStored;

  /// How often buffered events are flushed automatically.
  final Duration collectInterval;

  /// Metadata attached to every flushed batch.
  final Map<String, dynamic> exporterMetadata;

  /// Logger used to report flush failures, if provided.
  final Logger? logger;

  final List<dynamic> _events = [];
  Timer? _timer;
  bool _flushing = false;

  /// Starts the periodic flush timer.
  void start() {
    _timer = Timer.periodic(collectInterval, (_) => unawaited(flush()));
  }

  /// Cancels the periodic flush timer and flushes any remaining buffered
  /// events.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await flush();
  }

  /// Adds [event] to the buffer, flushing first if the buffer is full.
  Future<void> addEvent(dynamic event) async {
    if (_events.length >= maxEventStored) {
      await flush();
    }
    _events.add(event);
  }

  /// Sends buffered events to the relay-proxy.
  ///
  /// Events remain buffered if the request fails, matching the Go SDK's
  /// at-least-once delivery behavior.
  Future<void> flush() async {
    if (_flushing || _events.isEmpty) return;
    _flushing = true;
    final toSend = List<dynamic>.of(_events);
    try {
      await api.collectData(toSend, exporterMetadata);
      _events.removeRange(0, toSend.length);
    } on Object catch (e) {
      logger?.warning("Failed to send events to the data collector: $e");
    } finally {
      _flushing = false;
    }
  }
}
