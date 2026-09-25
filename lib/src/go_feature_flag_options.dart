/// @docImport 'go_feature_flag_provider.dart';
library;

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Configuration for [GoFeatureFlagProvider] (REMOTE evaluation mode).
///
/// Mirrors the relevant subset of the Go SDK's `gofeatureflag.ProviderOptions`
/// for `EvaluationTypeRemote`.
class GoFeatureFlagOptions {
  GoFeatureFlagOptions({
    required this.endpoint,
    this.httpClient,
    this.apiKey,
    this.headers = const {},
    this.exporterMetadata = const {},
    this.flagCacheSize = 10000,
    this.flagCacheTtl = const Duration(minutes: 1),
    this.disableCache = false,
    this.flagChangePollingInterval = const Duration(minutes: 2),
    this.dataCollectorMaxEventStored = 100000,
    this.dataCollectorCollectInterval = const Duration(minutes: 2),
    this.dataCollectorDisabled = false,
    this.dataCollectorBaseUrl,
    Logger? logger,
  }) : logger = logger ?? Logger("GoFeatureFlagProvider");

  /// Base URL of the GO Feature Flag relay-proxy (e.g.
  /// `http://localhost:1031`).
  final String endpoint;

  /// HTTP client used for every request.
  ///
  /// When omitted, [GoFeatureFlagProvider] creates a plain `http.Client()` and
  /// closes it on shutdown; a client supplied here is assumed to be owned by
  /// the caller and is never closed by the provider.
  final http.Client? httpClient;

  /// Sent as the `X-API-Key` header when the relay-proxy requires
  /// authentication.
  final String? apiKey;

  /// Extra headers added to every request (e.g. a custom `Authorization`
  /// header).
  final Map<String, String> headers;

  /// Metadata attached to every exported evaluation/tracking event.
  final Map<String, dynamic> exporterMetadata;

  /// Maximum number of evaluation results held in the client-side cache.
  final int flagCacheSize;

  /// How long a cached evaluation result is considered fresh.
  ///
  /// A negative duration means cached entries never expire.
  final Duration flagCacheTtl;

  /// Whether client-side evaluation caching is disabled entirely.
  final bool disableCache;

  /// How often the provider checks for flag configuration changes (via ETag) to
  /// invalidate the evaluation cache.
  final Duration flagChangePollingInterval;

  /// Maximum number of buffered events before the collector flushes early.
  final int dataCollectorMaxEventStored;

  /// Interval at which buffered events are flushed to the relay-proxy.
  final Duration dataCollectorCollectInterval;

  /// Whether event collection and tracking export is disabled entirely.
  final bool dataCollectorDisabled;

  /// Override for the base URL used only for the data collector endpoint,
  /// instead of [endpoint].
  final String? dataCollectorBaseUrl;

  /// Logger used to report background failures (e.g. failed polling or
  /// event-flush attempts).
  ///
  /// Defaults to a [Logger] named `"GoFeatureFlagProvider"`.
  final Logger logger;

  /// A concise, credential-safe representation for logs.
  ///
  /// [apiKey] and [headers] are deliberately omitted since they may hold
  /// credentials.
  @override
  String toString() =>
      "GoFeatureFlagOptions(endpoint: $endpoint, "
      "disableCache: $disableCache, flagCacheSize: $flagCacheSize, "
      "flagCacheTtl: $flagCacheTtl, "
      "flagChangePollingInterval: $flagChangePollingInterval, "
      "dataCollectorDisabled: $dataCollectorDisabled)";
}
