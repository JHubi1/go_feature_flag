# go_feature_flag

An [OpenFeature](https://openfeature.dev) provider for
[GO Feature Flag](https://gofeatureflag.org), for the
[`openfeature_dart_server_sdk`](https://pub.dev/packages/openfeature_dart_server_sdk).

This provider implements **REMOTE** evaluation mode: every flag evaluation is delegated to a GO Feature Flag relay-proxy over the OpenFeature Remote Evaluation Protocol (OFREP). It supports optional client-side evaluation caching (invalidated automatically when the relay-proxy's flag configuration changes) and exports flag usage/tracking events to the relay-proxy's data collector.

> INPROCESS evaluation mode (local evaluation without a relay-proxy) is not implemented by this package.

## Features

- Boolean/string/integer/double/object flag evaluation via OFREP.
- Optional client-side caching with TTL and size limits; the cache is purged automatically when the relay-proxy's flag configuration ETag changes.
- Buffered evaluation and tracking event export to the relay-proxy's data collector (`POST /v1/data/collector`).
- OpenFeature `track()` support.

## Getting started

Add the dependency and point the provider at a running [go-feature-flag relay-proxy](https://gofeatureflag.org/docs/relay_proxy):

```yaml
dependencies:
  go_feature_flag: ^0.1.0
```

## Usage

```dart
import 'package:go_feature_flag/go_feature_flag.dart';
import 'package:openfeature_dart_server_sdk/evaluation_context.dart';
import 'package:openfeature_dart_server_sdk/open_feature_api.dart';

Future<void> main() async {
  final api = OpenFeatureAPI();
  await api.setProviderAndWait(
    GoFeatureFlagProvider(
      GoFeatureFlagOptions(endpoint: "http://localhost:1031"),
    ),
  );

  final client = api.getClient("my-app");
  final adminFlag = await client.getBooleanFlag(
    "flag-only-for-admin",
    defaultValue: false,
    context: EvaluationContext.immutable(
      targetingKey: "1d1b9238-2591-4a47-94cf-d2bc080892f1",
      attributes: {"admin": true},
    ),
  );
  print("flag-only-for-admin: $adminFlag");

  await api.shutdown();
}
```

See `example/go_feature_flag_example.dart` for a runnable example.

> `getClient(name)`'s `name` argument (`"my-app"` above) is an OpenFeature SDK client identifier, not the provider's `domain` (a separate, optional named parameter); this provider does not read or forward either value anywhere.

## Provider options

`GoFeatureFlagOptions.endpoint` is required. The other options are optional:

| Option                         | Description                                                       | Default                 |
| ------------------------------ | ----------------------------------------------------------------- | ----------------------- |
| `httpClient`                   | Custom `http.Client`.                                             | a plain `http.Client()` |
| `apiKey`                       | Sent as `X-API-Key` when the relay-proxy requires authentication. | none                    |
| `headers`                      | Extra headers added to every request.                             | `{}`                    |
| `exporterMetadata`             | Metadata attached to every exported event.                        | `{}`                    |
| `disableCache`                 | Disables client-side evaluation caching.                          | `false`                 |
| `flagCacheSize`                | Max entries in the evaluation cache.                              | `10000`                 |
| `flagCacheTtl`                 | How long a cached result stays fresh.                             | 1 minute                |
| `flagChangePollingInterval`    | How often the cache-invalidation ETag check runs.                 | 2 minutes               |
| `dataCollectorDisabled`        | Disables event collection and tracking export.                    | `false`                 |
| `dataCollectorMaxEventStored`  | Buffer size before an early flush.                                | `100000`                |
| `dataCollectorCollectInterval` | How often buffered events are flushed.                            | 2 minutes               |
| `dataCollectorBaseUrl`         | Overrides the base URL used only for the data collector.          | same as `endpoint`      |

## Additional information

See the [GO Feature Flag documentation](https://gofeatureflag.org/docs) and the [Go SDK's REMOTE mode reference](https://github.com/open-feature/go-sdk-contrib/tree/main/providers/go-feature-flag) that this package mirrors.
