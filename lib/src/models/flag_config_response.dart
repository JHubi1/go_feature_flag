/// Parsed response from `POST /v1/flag/configuration` on the relay-proxy.
///
/// Only the ETag is needed for REMOTE evaluation (used to detect flag
/// configuration changes and invalidate the client-side cache); the full flag
/// definitions are not parsed since evaluation happens remotely.
class FlagConfigResponse {
  const FlagConfigResponse({required this.etag});

  /// The `ETag` response header, to be replayed as `If-None-Match`.
  final String etag;

  @override
  String toString() => "FlagConfigResponse(etag: $etag)";
}
