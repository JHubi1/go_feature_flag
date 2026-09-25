/// An event sent to the relay-proxy data collector, recording a custom tracking
/// call (mirrors the Go SDK's `model.TrackingEvent`).
class TrackingEvent {
  TrackingEvent({
    required this.contextKind,
    required this.userKey,
    required this.creationDate,
    required this.key,
    required this.evaluationContext,
    required this.trackingEventDetails,
  });

  final String kind = "tracking";
  final String contextKind;
  final String userKey;

  /// Unix timestamp in seconds.
  final int creationDate;

  /// The tracking event name.
  final String key;

  /// A snapshot of the evaluation context active when the event was tracked.
  final Map<String, dynamic> evaluationContext;

  /// The tracking call's `value` and custom attributes, snapshotted at call
  /// time.
  final Map<String, dynamic> trackingEventDetails;

  Map<String, dynamic> toJson() => {
    "kind": kind,
    "contextKind": contextKind,
    "userKey": userKey,
    "creationDate": creationDate,
    "key": key,
    "evaluationContext": evaluationContext,
    "trackingEventDetails": trackingEventDetails,
  };

  @override
  String toString() => "TrackingEvent(${toJson()})";
}
