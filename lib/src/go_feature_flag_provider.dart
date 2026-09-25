import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:openfeature_dart_server_sdk/evaluation_context.dart';
import 'package:openfeature_dart_server_sdk/feature_provider.dart';
import 'package:openfeature_dart_server_sdk/hooks.dart' show Hook;
import 'package:openfeature_dart_server_sdk/open_feature_event.dart';
import 'package:openfeature_dart_server_sdk/provider_capabilities.dart';
import 'package:openfeature_dart_server_sdk/provider_lifecycle.dart';

import 'data_collector_manager.dart';
import 'evaluation_cache.dart';
import 'go_feature_flag_options.dart';
import 'hooks/data_collector_hook.dart';
import 'hooks/evaluation_enrichment_hook.dart';
import 'json_snapshot.dart';
import 'models/tracking_event.dart';
import 'ofrep_client.dart';
import 'relay_proxy_api.dart';

/// OpenFeature provider for [GO Feature Flag](https://gofeatureflag.org),
/// delegating every evaluation to a relay-proxy via OFREP (REMOTE mode).
///
/// Optionally caches evaluation results client-side and polls the relay-proxy's
/// flag configuration ETag to purge the cache when flags change. See the Go
/// SDK's REMOTE mode for the reference behavior this mirrors.
class GoFeatureFlagProvider
    implements
        Provider,
        ProviderInitialization,
        ProviderShutdown,
        ProviderHooks,
        ProviderTracking {
  /// Creates a provider configured by [options].
  ///
  /// When [GoFeatureFlagOptions.httpClient] is omitted, this provider creates
  /// its own `http.Client` and closes it in [shutdownProvider].
  factory GoFeatureFlagProvider(GoFeatureFlagOptions options) {
    final httpClient = options.httpClient ?? http.Client();
    return GoFeatureFlagProvider._(
      options,
      httpClient,
      ownsHttpClient: options.httpClient == null,
    );
  }

  GoFeatureFlagProvider._(
    this._options,
    this._httpClient, {
    required this.ownsHttpClient,
  }) : _ofrepClient = OfrepClient(
         endpoint: _options.endpoint,
         httpClient: _httpClient,
         apiKey: _options.apiKey,
         headers: _options.headers,
       ),
       _relayProxyApi = RelayProxyApi(
         endpoint: _options.endpoint,
         httpClient: _httpClient,
         apiKey: _options.apiKey,
         headers: _options.headers,
         dataCollectorBaseUrl: _options.dataCollectorBaseUrl,
       ),
       _cache = EvaluationCache(
         maxSize: _options.flagCacheSize,
         ttl: _options.flagCacheTtl,
         disabled: _options.disableCache,
       ) {
    _dataCollectorManager = DataCollectorManager(
      api: _relayProxyApi,
      maxEventStored: _options.dataCollectorMaxEventStored,
      collectInterval: _options.dataCollectorCollectInterval,
      exporterMetadata: _options.exporterMetadata,
      logger: _options.logger,
    );
  }

  final GoFeatureFlagOptions _options;
  final http.Client _httpClient;

  /// Whether this provider created [_httpClient] itself (rather than receiving
  /// one via [GoFeatureFlagOptions.httpClient]), and is therefore responsible
  /// for closing it on [shutdownProvider].
  final bool ownsHttpClient;
  final OfrepClient _ofrepClient;
  final RelayProxyApi _relayProxyApi;
  final EvaluationCache _cache;
  late final DataCollectorManager _dataCollectorManager;

  final _eventsController = StreamController<ProviderLifecycleEvent>.broadcast(
    sync: true,
  );
  Timer? _pollingTimer;
  String? _lastEtag;

  @override
  ProviderMetadata get metadata =>
      const ProviderMetadata(name: "GO Feature Flag Provider");

  @override
  Stream<ProviderLifecycleEvent> get providerEvents => _eventsController.stream;

  @override
  String toString() =>
      "GoFeatureFlagProvider(endpoint: ${_options.endpoint}, "
      "disableCache: ${_options.disableCache}, "
      "dataCollectorDisabled: ${_options.dataCollectorDisabled})";

  @override
  List<Hook> get hooks => [
    EvaluationEnrichmentHook(_options.exporterMetadata),
    if (!_options.dataCollectorDisabled)
      DataCollectorHook(_dataCollectorManager),
  ];

  /// Fetches a baseline configuration ETag, starts the cache-invalidation
  /// polling timer and the data collector (unless disabled), then emits
  /// `PROVIDER_READY`.
  ///
  /// A failure to fetch the baseline configuration is logged but does not fail
  /// initialization; the relay-proxy remains the source of truth for every
  /// evaluation regardless.
  @override
  Future<void> initializeProvider(
    EvaluationContext context, {
    String? domain,
  }) async {
    if (!_options.disableCache) {
      try {
        final config = await _relayProxyApi.getConfiguration();
        _lastEtag = config?.etag;
      } on Object catch (e) {
        _options.logger.warning(
          "Failed to fetch initial flag configuration: $e",
        );
      }
      _startPolling();
    }

    if (!_options.dataCollectorDisabled) {
      _dataCollectorManager.start();
    }

    _eventsController.add(
      ProviderLifecycleEvent(
        OpenFeatureEventType.PROVIDER_READY,
        "GO Feature Flag provider is ready.",
      ),
    );
  }

  void _startPolling() {
    // Periodically re-checks the relay-proxy's configuration ETag; a change
    // means flags may have been updated, so the evaluation cache is purged.
    _pollingTimer = Timer.periodic(_options.flagChangePollingInterval, (
      _,
    ) async {
      try {
        final config = await _relayProxyApi.getConfiguration(etag: _lastEtag);
        if (config != null && config.etag != _lastEtag) {
          _lastEtag = config.etag;
          _cache.clear();
          _eventsController.add(
            ProviderLifecycleEvent(
              OpenFeatureEventType.PROVIDER_CONFIGURATION_CHANGED,
              "GO Feature Flag configuration changed; evaluation cache purged.",
            ),
          );
        }
      } on Object catch (e) {
        _options.logger.warning("Failed to poll flag configuration: $e");
      }
    });
  }

  /// Stops cache-invalidation polling, flushes and stops the data collector,
  /// and closes the `http.Client` if [ownsHttpClient].
  @override
  Future<void> shutdownProvider() async {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    if (!_options.dataCollectorDisabled) {
      await _dataCollectorManager.stop();
    }
    await _eventsController.close();
    if (ownsHttpClient) _httpClient.close();
  }

  /// Records a tracking event for later delivery to the data collector.
  ///
  /// A no-op (with a warning logged) when
  /// [GoFeatureFlagOptions.dataCollectorDisabled] is `true`.
  @override
  Future<void> trackEvent(
    String name, {
    Map<String, dynamic>? evaluationContext,
    TrackingEventDetails? trackingDetails,
  }) async {
    if (_options.dataCollectorDisabled) {
      _options.logger.warning(
        'Data collector is disabled, skipping tracking event "$name".',
      );
      return;
    }
    final context = evaluationContext ?? const <String, dynamic>{};
    final anonymous = context["anonymous"] == true;
    await _dataCollectorManager.addEvent(
      TrackingEvent(
        contextKind: anonymous ? "anonymousUser" : "user",
        userKey: context["targetingKey"] as String? ?? "undefined",
        creationDate: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        key: name,
        evaluationContext: jsonSnapshotMap(context),
        trackingEventDetails: {
          if (trackingDetails?.value != null) "value": trackingDetails!.value,
          ...jsonSnapshotMap(trackingDetails?.attributes ?? const {}),
        },
      ),
    );
  }

  /// Resolves [flagKey] against the client-side cache, then OFREP.
  ///
  /// Returns a `TYPE_MISMATCH` error result when the relay-proxy's resolved
  /// value isn't a [bool].
  @override
  Future<FlagEvaluationResult<bool>> getBooleanFlag(
    String flagKey,
    bool defaultValue, {
    Map<String, dynamic>? context,
  }) => _evaluate<bool>(
    flagKey,
    defaultValue,
    context,
    (v) => v is bool ? v : null,
  );

  @override
  Future<FlagEvaluationResult<String>> getStringFlag(
    String flagKey,
    String defaultValue, {
    Map<String, dynamic>? context,
  }) => _evaluate<String>(
    flagKey,
    defaultValue,
    context,
    (v) => v is String ? v : null,
  );

  @override
  Future<FlagEvaluationResult<int>> getIntegerFlag(
    String flagKey,
    int defaultValue, {
    Map<String, dynamic>? context,
  }) => _evaluate<int>(flagKey, defaultValue, context, (v) {
    if (v is int) return v;
    if (v is double && v == v.roundToDouble()) return v.toInt();
    return null;
  });

  @override
  Future<FlagEvaluationResult<double>> getDoubleFlag(
    String flagKey,
    double defaultValue, {
    Map<String, dynamic>? context,
  }) => _evaluate<double>(flagKey, defaultValue, context, (v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return null;
  });

  @override
  Future<FlagEvaluationResult<Map<String, dynamic>>> getObjectFlag(
    String flagKey,
    Map<String, dynamic> defaultValue, {
    Map<String, dynamic>? context,
  }) => _evaluate<Map<String, dynamic>>(
    flagKey,
    defaultValue,
    context,
    (v) => v is Map ? Map<String, dynamic>.from(v) : null,
  );

  /// Resolves a cache hit or OFREP evaluation for [flagKey] into a
  /// [FlagEvaluationResult], applying [convert] to coerce the raw value into
  /// `T` and reporting a `TYPE_MISMATCH` error when [convert] returns `null`.
  ///
  /// Cache hits are re-tagged with a `"CACHED"` reason; cacheable OFREP
  /// responses (`metadata.gofeatureflag_cacheable == true`) are stored for
  /// later cache hits.
  Future<FlagEvaluationResult<T>> _evaluate<T>(
    String flagKey,
    T defaultValue,
    Map<String, dynamic>? context,
    T? Function(Object? value) convert,
  ) async {
    final evalCtx = context ?? const <String, dynamic>{};

    final cached = _cache.get(flagKey, evalCtx);
    if (cached != null) {
      return _toResult(
        flagKey,
        defaultValue,
        cached,
        convert,
        reasonOverride: "CACHED",
      );
    }

    final result = await _ofrepClient.evaluate(flagKey, evalCtx);
    if (!result.isError && result.isCacheable) {
      _cache.set(flagKey, evalCtx, result);
    }
    return _toResult(flagKey, defaultValue, result, convert);
  }

  /// Converts an [OfrepResult] (or cached equivalent) into a
  /// [FlagEvaluationResult], applying [reasonOverride] when serving a cache
  /// hit.
  FlagEvaluationResult<T> _toResult<T>(
    String flagKey,
    T defaultValue,
    OfrepResult result,
    T? Function(Object? value) convert, {
    String? reasonOverride,
  }) {
    if (result.isError) {
      return FlagEvaluationResult.error<T>(
        flagKey,
        defaultValue,
        result.errorCode!,
        result.errorMessage ?? "evaluation error",
        evaluatorId: metadata.name,
      );
    }
    final converted = convert(result.value);
    if (converted == null) {
      return FlagEvaluationResult.error<T>(
        flagKey,
        defaultValue,
        ErrorCode.TYPE_MISMATCH,
        "resolved value ${result.value} is not of the expected type",
        evaluatorId: metadata.name,
      );
    }
    return FlagEvaluationResult<T>(
      flagKey: flagKey,
      value: converted,
      reason: reasonOverride ?? result.reason,
      variant: result.variant,
      flagMetadata: result.metadata,
      evaluatedAt: DateTime.now(),
      evaluatorId: metadata.name,
    );
  }
}
