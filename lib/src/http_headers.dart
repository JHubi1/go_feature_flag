/// Builds the standard headers sent with every request to the relay-proxy
/// (content type, optional API key, and any user-supplied extra headers).
Map<String, String> buildRequestHeaders({
  required String? apiKey,
  required Map<String, String> extraHeaders,
  String? ifNoneMatch,
}) {
  return {
    "Content-Type": "application/json",
    if (apiKey != null && apiKey.isNotEmpty) "X-API-Key": apiKey,
    "If-None-Match": ?ifNoneMatch,
    ...extraHeaders,
  };
}
