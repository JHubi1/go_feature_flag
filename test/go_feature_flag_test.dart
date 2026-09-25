import 'dart:convert';

import 'package:go_feature_flag/go_feature_flag.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfeature_dart_server_sdk/client.dart';
import 'package:openfeature_dart_server_sdk/evaluation_context.dart';
import 'package:openfeature_dart_server_sdk/feature_provider.dart';
import 'package:openfeature_dart_server_sdk/open_feature_api.dart';
import 'package:test/test.dart';

/// A minimal fake relay-proxy: routes requests by path and records every
/// request body so tests can assert on OFREP/data-collector traffic.
class _FakeRelayProxy {
  _FakeRelayProxy();

  final requests = <http.Request>[];
  final Map<String, Map<String, dynamic>> flags = {};

  /// Overrides the response for a specific flag key with an arbitrary raw
  /// HTTP response, bypassing [flags]; used to simulate transport-level
  /// errors (invalid JSON, unauthorized, rate limiting, etc.).
  final Map<String, http.Response> rawFlagResponses = {};
  int etagCallCount = 0;

  http.Client get client => MockClient((request) async {
    requests.add(request);
    final path = request.url.path;

    if (path == "/v1/flag/configuration") {
      etagCallCount++;
      return http.Response(
        "{}",
        200,
        headers: {"etag": '"etag-$etagCallCount"'},
      );
    }

    if (path == "/v1/data/collector") {
      return http.Response('{"ingestedContentCount":1}', 200);
    }

    if (path.startsWith("/ofrep/v1/evaluate/flags/")) {
      final flagKey = Uri.decodeComponent(path.split("/").last);
      final rawResponse = rawFlagResponses[flagKey];
      if (rawResponse != null) return rawResponse;
      final flag = flags[flagKey];
      if (flag == null) {
        return http.Response(
          jsonEncode({
            "errorCode": "FLAG_NOT_FOUND",
            "errorDetails": "flag $flagKey not found",
          }),
          404,
        );
      }
      return http.Response(jsonEncode(flag), 200);
    }

    return http.Response("not found", 404);
  });
}

Map<String, dynamic> _successBody(
  Object? value, {
  String reason = "STATIC",
  String variant = "default",
  bool cacheable = false,
}) => {
  "value": value,
  "key": "flag",
  "reason": reason,
  "variant": variant,
  "metadata": {if (cacheable) "gofeatureflag_cacheable": true},
};

void main() {
  late _FakeRelayProxy relayProxy;

  setUp(() {
    relayProxy = _FakeRelayProxy();
  });

  tearDown(() async {
    await OpenFeatureAPI.resetInstance();
  });

  GoFeatureFlagProvider buildProvider({
    bool disableCache = false,
    int flagCacheSize = 10000,
    Duration flagCacheTtl = const Duration(minutes: 1),
  }) => GoFeatureFlagProvider(
    GoFeatureFlagOptions(
      endpoint: "https://gofeatureflag.example",
      httpClient: relayProxy.client,
      disableCache: disableCache,
      flagCacheSize: flagCacheSize,
      flagCacheTtl: flagCacheTtl,
      flagChangePollingInterval: const Duration(minutes: 10),
      dataCollectorCollectInterval: const Duration(minutes: 10),
    ),
  );

  test("resolves a boolean flag successfully", () async {
    relayProxy.flags["bool-flag"] = _successBody(
      true,
      reason: "TARGETING_MATCH",
      variant: "enabled",
    );
    final api = OpenFeatureAPI();
    await api.setProviderAndWait(buildProvider());
    final client = api.getClient("test-app");

    final details = await client.getBooleanDetails(
      "bool-flag",
      defaultValue: false,
    );

    expect(details.value, isTrue);
    expect(details.reason, "TARGETING_MATCH");
    expect(details.variant, "enabled");
    expect(details.errorCode, isNull);
  });

  test("returns FLAG_NOT_FOUND for an unknown flag", () async {
    final api = OpenFeatureAPI();
    await api.setProviderAndWait(buildProvider());
    final client = api.getClient("test-app");

    final details = await client.getBooleanDetails(
      "missing-flag",
      defaultValue: false,
    );

    expect(details.value, isFalse);
    expect(details.errorCode, ErrorCode.FLAG_NOT_FOUND);
  });

  test(
    "returns TYPE_MISMATCH when the resolved value has the wrong type",
    () async {
      relayProxy.flags["string-flag"] = _successBody("not-a-bool");
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider());
      final client = api.getClient("test-app");

      final details = await client.getBooleanDetails(
        "string-flag",
        defaultValue: false,
      );

      expect(details.errorCode, ErrorCode.TYPE_MISMATCH);
    },
  );

  test(
    "caches a cacheable evaluation and serves the second call from cache",
    () async {
      relayProxy.flags["cacheable-flag"] = _successBody(
        true,
        variant: "on",
        cacheable: true,
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider());
      final client = api.getClient("test-app");

      final first = await client.getBooleanDetails(
        "cacheable-flag",
        defaultValue: false,
      );
      final second = await client.getBooleanDetails(
        "cacheable-flag",
        defaultValue: false,
      );

      expect(first.reason, "STATIC");
      expect(second.reason, "CACHED");
      expect(
        relayProxy.requests.where((r) => r.url.path.contains("/ofrep/")).length,
        1,
      );
    },
  );

  test("does not cache a non-cacheable evaluation", () async {
    relayProxy.flags["non-cacheable-flag"] = _successBody(true);
    final api = OpenFeatureAPI();
    await api.setProviderAndWait(buildProvider());
    final client = api.getClient("test-app");

    await client.getBooleanDetails("non-cacheable-flag", defaultValue: false);
    await client.getBooleanDetails("non-cacheable-flag", defaultValue: false);

    expect(
      relayProxy.requests.where((r) => r.url.path.contains("/ofrep/")).length,
      2,
    );
  });

  test(
    "flushes a data collector event for a cached evaluation on shutdown",
    () async {
      relayProxy.flags["cacheable-flag"] = _successBody(
        true,
        variant: "on",
        cacheable: true,
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider());
      final client = api.getClient("test-app");

      await client.getBooleanDetails(
        "cacheable-flag",
        defaultValue: false,
      ); // miss
      await client.getBooleanDetails(
        "cacheable-flag",
        defaultValue: false,
      ); // hit -> collected
      await api.shutdown();

      final collectorRequest = relayProxy.requests.firstWhere(
        (r) => r.url.path == "/v1/data/collector",
      );
      final body = jsonDecode(collectorRequest.body) as Map<String, dynamic>;
      final events = body["events"] as List;
      expect(events, hasLength(1));
      expect(events.single["source"], "PROVIDER_CACHE");
      expect(events.single["key"], "cacheable-flag");
    },
  );

  test("snapshots the SDK default value before buffering an error event "
      "(guards against caller mutation before the event is flushed)", () async {
    final api = OpenFeatureAPI();
    await api.setProviderAndWait(buildProvider());
    final client = api.getClient("test-app");

    final mutableDefault = {"flag": "original"};
    await client.getObjectFlag(
      "missing-object-flag",
      defaultValue: mutableDefault,
    );
    mutableDefault["flag"] = "mutated-after-call";
    await api.shutdown();

    final collectorRequest = relayProxy.requests.firstWhere(
      (r) => r.url.path == "/v1/data/collector",
    );
    final body = jsonDecode(collectorRequest.body) as Map<String, dynamic>;
    final events = body["events"] as List;
    expect(events, hasLength(1));
    expect(events.single["value"], {"flag": "original"});
  });

  test("sends a tracking event to the data collector", () async {
    final api = OpenFeatureAPI();
    await api.setProviderAndWait(buildProvider());
    final client = api.getClient("test-app");

    await client.track(
      "checkout-completed",
      context: const EvaluationContext(
        targetingKey: "user-123",
        attributes: {},
      ),
      trackingDetails: const TrackingEventDetails(
        value: 99.99,
        attributes: {"currency": "USD"},
      ),
    );
    await api.shutdown();

    final collectorRequest = relayProxy.requests.firstWhere(
      (r) => r.url.path == "/v1/data/collector",
    );
    final body = jsonDecode(collectorRequest.body) as Map<String, dynamic>;
    final events = body["events"] as List;
    expect(events, hasLength(1));
    expect(events.single["kind"], "tracking");
    expect(events.single["key"], "checkout-completed");
    expect(events.single["userKey"], "user-123");
  });

  test("snapshots the tracking context and details before buffering "
      "(guards against caller mutation before the event is flushed)", () async {
    final api = OpenFeatureAPI();
    await api.setProviderAndWait(buildProvider());
    final client = api.getClient("test-app");

    final contextItems = ["a"];
    final detailsTags = ["x"];
    final mutableContextAttrs = {"items": contextItems};
    final mutableDetailsAttrs = {"tags": detailsTags};
    await client.track(
      "checkout-completed",
      context: EvaluationContext(
        targetingKey: "user-123",
        attributes: mutableContextAttrs,
      ),
      trackingDetails: TrackingEventDetails(attributes: mutableDetailsAttrs),
    );
    contextItems.add("mutated");
    detailsTags.add("mutated");
    await api.shutdown();

    final collectorRequest = relayProxy.requests.firstWhere(
      (r) => r.url.path == "/v1/data/collector",
    );
    final body = jsonDecode(collectorRequest.body) as Map<String, dynamic>;
    final events = body["events"] as List;
    expect(events, hasLength(1));
    expect(events.single["evaluationContext"]["items"], ["a"]);
    expect(events.single["trackingEventDetails"]["tags"], ["x"]);
  });

  test("enriches the evaluation context sent to the relay-proxy", () async {
    relayProxy.flags["bool-flag"] = _successBody(true);
    final api = OpenFeatureAPI();
    await api.setProviderAndWait(
      GoFeatureFlagProvider(
        GoFeatureFlagOptions(
          endpoint: "https://gofeatureflag.example",
          httpClient: relayProxy.client,
          exporterMetadata: const {"openfeature": true},
          flagChangePollingInterval: const Duration(minutes: 10),
        ),
      ),
    );
    final client = api.getClient("test-app");

    await client.getBooleanDetails("bool-flag", defaultValue: false);

    final ofrepRequest = relayProxy.requests.firstWhere(
      (r) => r.url.path.contains("/ofrep/"),
    );
    final body = jsonDecode(ofrepRequest.body) as Map<String, dynamic>;
    final context = body["context"] as Map<String, dynamic>;
    expect(context["gofeatureflag"]["exporterMetadata"], {"openfeature": true});
  });

  test("sends the configured API key as the X-API-Key header", () async {
    relayProxy.flags["bool-flag"] = _successBody(true);
    final api = OpenFeatureAPI();
    await api.setProviderAndWait(
      GoFeatureFlagProvider(
        GoFeatureFlagOptions(
          endpoint: "https://gofeatureflag.example",
          httpClient: relayProxy.client,
          apiKey: "my-api-key",
          flagChangePollingInterval: const Duration(minutes: 10),
        ),
      ),
    );
    final client = api.getClient("test-app");

    await client.getBooleanDetails("bool-flag", defaultValue: false);

    final ofrepRequest = relayProxy.requests.firstWhere(
      (r) => r.url.path.contains("/ofrep/"),
    );
    expect(ofrepRequest.headers["X-API-Key"], "my-api-key");
  });

  group("client-side cache", () {
    test(
      "treats different evaluation contexts as distinct cache entries",
      () async {
        relayProxy.flags["cacheable-flag"] = _successBody(
          true,
          variant: "on",
          cacheable: true,
        );
        final api = OpenFeatureAPI();
        await api.setProviderAndWait(buildProvider());
        final client = api.getClient("test-app");

        for (final userId in ["user-1", "user-2", "user-3"]) {
          final details = await client.getBooleanDetails(
            "cacheable-flag",
            defaultValue: false,
            context: EvaluationContext(targetingKey: userId, attributes: {}),
          );
          expect(details.reason, isNot("CACHED"));
        }

        expect(
          relayProxy.requests
              .where((r) => r.url.path.contains("/ofrep/"))
              .length,
          3,
        );
      },
    );

    test("evicts the least-recently-used entry once full", () async {
      relayProxy.flags["cacheable-flag"] = _successBody(
        true,
        variant: "on",
        cacheable: true,
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider(flagCacheSize: 2));
      final client = api.getClient("test-app");

      const ctx1 = EvaluationContext(targetingKey: "ctx-1", attributes: {});
      const ctx2 = EvaluationContext(targetingKey: "ctx-2", attributes: {});
      const ctx3 = EvaluationContext(targetingKey: "ctx-3", attributes: {});

      Future<String?> reasonFor(EvaluationContext ctx) async =>
          (await client.getBooleanDetails(
            "cacheable-flag",
            defaultValue: false,
            context: ctx,
          )).reason;

      expect(await reasonFor(ctx1), isNot("CACHED")); // miss
      expect(await reasonFor(ctx1), "CACHED"); // hit
      expect(await reasonFor(ctx2), isNot("CACHED")); // miss
      expect(await reasonFor(ctx2), "CACHED"); // hit
      expect(await reasonFor(ctx3), isNot("CACHED")); // miss, evicts ctx1 (LRU)
      expect(await reasonFor(ctx1), isNot("CACHED")); // evicted, re-fetches

      expect(
        relayProxy.requests.where((r) => r.url.path.contains("/ofrep/")).length,
        4,
      );
    });

    test("re-fetches once the cache TTL has expired", () async {
      relayProxy.flags["cacheable-flag"] = _successBody(
        true,
        variant: "on",
        cacheable: true,
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(
        buildProvider(flagCacheTtl: const Duration(milliseconds: 50)),
      );
      final client = api.getClient("test-app");

      await client.getBooleanDetails("cacheable-flag", defaultValue: false);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await client.getBooleanDetails("cacheable-flag", defaultValue: false);

      expect(
        relayProxy.requests.where((r) => r.url.path.contains("/ofrep/")).length,
        2,
      );
    });

    test("never serves from cache when caching is disabled", () async {
      relayProxy.flags["cacheable-flag"] = _successBody(
        true,
        variant: "on",
        cacheable: true,
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider(disableCache: true));
      final client = api.getClient("test-app");

      final first = await client.getBooleanDetails(
        "cacheable-flag",
        defaultValue: false,
      );
      final second = await client.getBooleanDetails(
        "cacheable-flag",
        defaultValue: false,
      );

      expect(first.reason, isNot("CACHED"));
      expect(second.reason, isNot("CACHED"));
      expect(
        relayProxy.requests.where((r) => r.url.path.contains("/ofrep/")).length,
        2,
      );
    });

    test("sends no data collector event for a non-cached evaluation", () async {
      relayProxy.flags["cacheable-flag"] = _successBody(
        true,
        variant: "on",
        cacheable: true,
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider());
      final client = api.getClient("test-app");

      await client.getBooleanDetails(
        "cacheable-flag",
        defaultValue: false,
      ); // miss, nothing collected
      await api.shutdown();

      expect(
        relayProxy.requests.where((r) => r.url.path == "/v1/data/collector"),
        isEmpty,
      );
    });
  });

  group("flag type evaluation", () {
    test("resolves a string flag successfully", () async {
      relayProxy.flags["string-flag"] = _successBody(
        "CC0000",
        reason: "TARGETING_MATCH",
        variant: "color1",
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider());
      final client = api.getClient("test-app");

      final details = await client.getStringDetails(
        "string-flag",
        defaultValue: "default",
      );

      expect(details.value, "CC0000");
      expect(details.reason, "TARGETING_MATCH");
      expect(details.variant, "color1");
    });

    test("resolves an integer flag successfully", () async {
      relayProxy.flags["int-flag"] = _successBody(
        100,
        reason: "TARGETING_MATCH",
        variant: "medium",
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider());
      final client = api.getClient("test-app");

      final details = await client.getIntegerDetails(
        "int-flag",
        defaultValue: 123,
      );

      expect(details.value, 100);
      expect(details.reason, "TARGETING_MATCH");
    });

    test(
      "resolves an integer flag from a whole-number double relay-proxy value",
      () async {
        relayProxy.flags["int-flag"] = _successBody(100.0);
        final api = OpenFeatureAPI();
        await api.setProviderAndWait(buildProvider());
        final client = api.getClient("test-app");

        final details = await client.getIntegerDetails(
          "int-flag",
          defaultValue: 123,
        );

        expect(details.value, 100);
        expect(details.errorCode, isNull);
      },
    );

    test("resolves a double flag successfully", () async {
      relayProxy.flags["double-flag"] = _successBody(
        100.25,
        reason: "TARGETING_MATCH",
        variant: "medium",
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider());
      final client = api.getClient("test-app");

      final details = await client.getDoubleDetails(
        "double-flag",
        defaultValue: 123.45,
      );

      expect(details.value, 100.25);
      expect(details.reason, "TARGETING_MATCH");
    });

    test("resolves an object flag successfully", () async {
      relayProxy.flags["object-flag"] = _successBody(
        {"test": "test1", "test2": false},
        reason: "TARGETING_MATCH",
        variant: "varA",
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider());
      final client = api.getClient("test-app");

      final details = await client.getObjectDetails(
        "object-flag",
        defaultValue: const {},
      );

      expect(details.value, {"test": "test1", "test2": false});
      expect(details.reason, "TARGETING_MATCH");
    });

    test(
      "returns TYPE_MISMATCH for an object flag when the value isn't a map",
      () async {
        relayProxy.flags["not-an-object-flag"] = _successBody("just a string");
        final api = OpenFeatureAPI();
        await api.setProviderAndWait(buildProvider());
        final client = api.getClient("test-app");

        final details = await client.getObjectDetails(
          "not-an-object-flag",
          defaultValue: const {},
        );

        expect(details.errorCode, ErrorCode.TYPE_MISMATCH);
      },
    );

    test(
      "passes through a custom evaluation reason from the relay-proxy",
      () async {
        relayProxy.flags["custom-reason-flag"] = _successBody(
          true,
          reason: "CUSTOM_REASON",
          variant: "enabled",
        );
        final api = OpenFeatureAPI();
        await api.setProviderAndWait(buildProvider());
        final client = api.getClient("test-app");

        final details = await client.getBooleanDetails(
          "custom-reason-flag",
          defaultValue: false,
        );

        expect(details.reason, "CUSTOM_REASON");
        expect(details.errorCode, isNull);
      },
    );
  });

  group("OFREP error handling", () {
    test(
      "returns a PARSE_ERROR when the response body isn't valid JSON",
      () async {
        relayProxy.rawFlagResponses["invalid-json-flag"] = http.Response(
          "not json",
          200,
        );
        final api = OpenFeatureAPI();
        await api.setProviderAndWait(buildProvider());
        final client = api.getClient("test-app");

        final details = await client.getBooleanDetails(
          "invalid-json-flag",
          defaultValue: false,
        );

        expect(details.errorCode, ErrorCode.PARSE_ERROR);
      },
    );

    test(
      "returns a GENERAL error when the relay-proxy responds unauthorized",
      () async {
        relayProxy.rawFlagResponses["unauthorized-flag"] = http.Response(
          "",
          401,
        );
        final api = OpenFeatureAPI();
        await api.setProviderAndWait(buildProvider());
        final client = api.getClient("test-app");

        final details = await client.getBooleanDetails(
          "unauthorized-flag",
          defaultValue: false,
        );

        expect(details.errorCode, ErrorCode.GENERAL);
      },
    );

    test(
      "returns a GENERAL error when rate limited by the relay-proxy",
      () async {
        relayProxy.rawFlagResponses["rate-limited-flag"] = http.Response(
          "",
          429,
        );
        final api = OpenFeatureAPI();
        await api.setProviderAndWait(buildProvider());
        final client = api.getClient("test-app");

        final details = await client.getBooleanDetails(
          "rate-limited-flag",
          defaultValue: false,
        );

        expect(details.errorCode, ErrorCode.GENERAL);
        expect(details.errorMessage, contains("rate limited"));
      },
    );

    test("maps a TARGETING_KEY_MISSING error code from a 400 response", () async {
      relayProxy.rawFlagResponses["targeting-key-missing-flag"] = http.Response(
        jsonEncode({
          "errorCode": "TARGETING_KEY_MISSING",
          "errorDetails": "targeting key is required",
        }),
        400,
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider());
      final client = api.getClient("test-app");

      final details = await client.getBooleanDetails(
        "targeting-key-missing-flag",
        defaultValue: false,
      );

      expect(details.errorCode, ErrorCode.TARGETING_KEY_MISSING);
      expect(details.errorMessage, "targeting key is required");
    });

    test("maps an INVALID_CONTEXT error code from a 400 response", () async {
      relayProxy.rawFlagResponses["invalid-context-flag"] = http.Response(
        jsonEncode({
          "errorCode": "INVALID_CONTEXT",
          "errorDetails": "context is malformed",
        }),
        400,
      );
      final api = OpenFeatureAPI();
      await api.setProviderAndWait(buildProvider());
      final client = api.getClient("test-app");

      final details = await client.getBooleanDetails(
        "invalid-context-flag",
        defaultValue: false,
      );

      expect(details.errorCode, ErrorCode.INVALID_CONTEXT);
    });
  });
}
