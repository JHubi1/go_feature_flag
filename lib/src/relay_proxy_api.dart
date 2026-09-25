import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_headers.dart';
import 'models/flag_config_response.dart';

/// Joins [endpoint] with the given path segments, tolerating a missing or
/// present trailing slash on the endpoint.
Uri joinUri(String endpoint, List<String> segments) {
  final base = Uri.parse(endpoint);
  final basePath = base.path.endsWith("/")
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  final path = [
    ...basePath.split("/").where((s) => s.isNotEmpty),
    ...segments,
  ].join("/");
  return base.replace(path: "/$path");
}

/// Low-level HTTP client for the GO Feature Flag relay-proxy endpoints that are
/// not part of the OFREP evaluation protocol: flag configuration (used for
/// ETag-based cache invalidation) and the data collector.
class RelayProxyApi {
  RelayProxyApi({
    required this.endpoint,
    required this.httpClient,
    this.apiKey,
    this.headers = const {},
    this.dataCollectorBaseUrl,
  });

  /// Base URL of the GO Feature Flag relay-proxy.
  final String endpoint;

  /// The HTTP client used for every request.
  final http.Client httpClient;

  /// Sent as the `X-API-Key` header, when set.
  final String? apiKey;

  /// Extra headers added to every request.
  final Map<String, String> headers;

  /// Overrides [endpoint] for the data collector request only, when set.
  final String? dataCollectorBaseUrl;

  /// Fetches the flag configuration ETag.
  ///
  /// Pass the previous [etag] to make a conditional request; returns `null`
  /// when the server responds `304 Not Modified` (i.e. the configuration has
  /// not changed).
  Future<FlagConfigResponse?> getConfiguration({String? etag}) async {
    final uri = joinUri(endpoint, ["v1", "flag", "configuration"]);
    final response = await httpClient.post(
      uri,
      headers: buildRequestHeaders(
        apiKey: apiKey,
        extraHeaders: headers,
        ifNoneMatch: etag,
      ),
      body: jsonEncode(const {}),
    );

    if (response.statusCode == 304) {
      return null;
    }
    if (response.statusCode != 200) {
      throw StateError(
        "getConfiguration: request failed with status "
        "${response.statusCode}: ${response.body}",
      );
    }
    final responseEtag = response.headers["etag"] ?? "";
    return FlagConfigResponse(etag: responseEtag);
  }

  /// Sends buffered [events] (each a `FeatureEvent` or `TrackingEvent` with a
  /// `toJson()` method) and [meta] to the data collector endpoint.
  Future<void> collectData(
    List<dynamic> events,
    Map<String, dynamic> meta,
  ) async {
    final base = dataCollectorBaseUrl ?? endpoint;
    final uri = joinUri(base, ["v1", "data", "collector"]);
    final response = await httpClient.post(
      uri,
      headers: buildRequestHeaders(apiKey: apiKey, extraHeaders: headers),
      body: jsonEncode({
        "events": events.map((e) => e.toJson()).toList(),
        "meta": meta,
      }),
    );

    if (response.statusCode != 200) {
      throw StateError(
        "collectData: request failed with status "
        "${response.statusCode}: ${response.body}",
      );
    }
  }
}
