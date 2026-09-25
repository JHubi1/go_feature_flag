/// An event sent to the relay-proxy data collector, recording one flag
/// evaluation (mirrors the Go SDK's `model.FeatureEvent`).
class FeatureEvent {
  FeatureEvent({
    required this.contextKind,
    required this.userKey,
    required this.creationDate,
    required this.key,
    required this.variation,
    required this.value,
    required this.isDefault,
    required this.source,
    this.version = "",
  });

  final String kind = "feature";

  /// `"anonymousUser"` or `"user"`, depending on the evaluation context.
  final String contextKind;

  /// The evaluation context's targeting key, or `"undefined"` when absent.
  final String userKey;

  /// Unix timestamp in seconds.
  final int creationDate;

  /// The evaluated flag's key.
  final String key;

  /// The variant name, or `"SdkDefault"` when [isDefault] is `true`.
  final String variation;

  /// The resolved flag value, or the SDK default value on error.
  final Object? value;

  /// Whether [value] is the SDK default rather than a value resolved by the
  /// relay-proxy.
  final bool isDefault;

  /// The flag's version, when known. Empty when not reported.
  final String version;

  /// `PROVIDER_CACHE` for evaluations served from the client-side cache.
  final String source;

  Map<String, dynamic> toJson() => {
    "kind": kind,
    "contextKind": contextKind,
    "userKey": userKey,
    "creationDate": creationDate,
    "key": key,
    "variation": variation,
    "value": value,
    "default": isDefault,
    "version": version,
    "source": source,
  };

  @override
  String toString() => "FeatureEvent(${toJson()})";
}
