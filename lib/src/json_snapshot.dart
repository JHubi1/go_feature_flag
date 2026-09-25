import 'dart:convert';

/// Deep-clones [value] via a JSON encode/decode round trip.
///
/// The OpenFeature SDK's legacy (non-`immutable`) `EvaluationContext` and
/// `TrackingEventDetails` constructors retain caller-owned values by reference
/// rather than snapshotting them. Since buffered events sit in
/// [DataCollectorManager] for up to `dataCollectorCollectInterval` before being
/// sent, holding onto those references directly would let a later caller-side
/// mutation change data that was already "collected". Falls back to
/// `toString()` for values that cannot be represented as JSON, so a
/// non-serializable value never breaks the event buffer.
Object? jsonSnapshot(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  try {
    return jsonDecode(jsonEncode(value));
  } on Object {
    return value.toString();
  }
}

/// Like [jsonSnapshot], specialized for `Map<String, dynamic>` contexts.
Map<String, dynamic> jsonSnapshotMap(Map<String, dynamic> map) {
  if (map.isEmpty) return const {};
  try {
    return (jsonDecode(jsonEncode(map)) as Map).cast<String, dynamic>();
  } on Object {
    return Map<String, dynamic>.from(map);
  }
}
