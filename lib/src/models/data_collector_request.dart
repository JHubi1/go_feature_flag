/// The request body for `POST /v1/data/collector`.
class DataCollectorRequest {
  const DataCollectorRequest({required this.events, required this.meta});

  /// Each element is a `FeatureEvent` or `TrackingEvent`.
  final List<dynamic> events;

  /// Exporter metadata attached to the whole batch.
  final Map<String, dynamic> meta;

  Map<String, dynamic> toJson() => {
    "events": events.map((e) => (e as dynamic).toJson()).toList(),
    "meta": meta,
  };

  @override
  String toString() => "DataCollectorRequest(${toJson()})";
}
