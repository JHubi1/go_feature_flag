import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:openfeature_dart_server_sdk/feature_provider.dart';

import 'http_headers.dart';
import 'relay_proxy_api.dart';

/// The outcome of a single OFREP flag evaluation call: either a value with
/// resolution metadata, or an error code/message.
class OfrepResult {
  const OfrepResult({
    this.value,
    this.reason = "ERROR",
    this.variant,
    this.metadata = const {},
    this.errorCode,
    this.errorMessage,
  });

  /// The resolved flag value on success, or `null` on error.
  final Object? value;

  /// The OFREP evaluation reason (e.g. `"STATIC"`, `"TARGETING_MATCH"`,
  /// `"DISABLED"`).
  final String reason;

  /// The resolved variant name, when reported by the relay-proxy.
  final String? variant;

  /// Flag resolution metadata reported by the relay-proxy, such as whether the
  /// result is safe to cache client-side.
  final Map<String, dynamic> metadata;

  /// The OpenFeature error code, or `null` on success.
  final ErrorCode? errorCode;

  /// A human-readable error description, or `null` on success.
  final String? errorMessage;

  /// Whether this result represents an evaluation error.
  bool get isError => errorCode != null;

  /// Whether the relay-proxy marked this evaluation safe to cache client-side.
  bool get isCacheable => metadata["gofeatureflag_cacheable"] == true;

  @override
  String toString() =>
      "OfrepResult(value: $value, reason: $reason, variant: $variant, "
      "metadata: $metadata, errorCode: $errorCode, "
      "errorMessage: $errorMessage)";
}

/// Client for the OpenFeature Remote Evaluation Protocol (OFREP) single-flag
/// evaluation endpoint exposed by the GO Feature Flag relay-proxy.
class OfrepClient {
  OfrepClient({
    required this.endpoint,
    required this.httpClient,
    this.apiKey,
    this.headers = const {},
  });

  /// Base URL of the GO Feature Flag relay-proxy.
  final String endpoint;

  /// The HTTP client used for every request.
  final http.Client httpClient;

  /// Sent as the `X-API-Key` header, when set.
  final String? apiKey;

  /// Extra headers added to every request.
  final Map<String, String> headers;

  /// Evaluates [flagKey] against [context] via OFREP.
  ///
  /// Returns an error [OfrepResult] instead of throwing when the request fails
  /// or the relay-proxy reports an evaluation error.
  Future<OfrepResult> evaluate(
    String flagKey,
    Map<String, dynamic> context,
  ) async {
    final uri = joinUri(endpoint, [
      "ofrep",
      "v1",
      "evaluate",
      "flags",
      Uri.encodeComponent(flagKey),
    ]);

    final http.Response response;
    try {
      response = await httpClient.post(
        uri,
        headers: buildRequestHeaders(apiKey: apiKey, extraHeaders: headers),
        body: jsonEncode({"context": context}),
      );
    } on Object catch (e) {
      return OfrepResult(
        errorCode: ErrorCode.GENERAL,
        errorMessage: "ofrep request failed: $e",
      );
    }

    return _parseResponse(response);
  }

  OfrepResult _parseResponse(http.Response response) {
    switch (response.statusCode) {
      case 200:
        return _parseSuccess(response.body);
      case 400:
        return _parseClientError(response.body);
      case 404:
        return OfrepResult(
          errorCode: ErrorCode.FLAG_NOT_FOUND,
          errorMessage: _errorDetailsOrDefault(response.body, "flag not found"),
        );
      case 429:
        return const OfrepResult(
          errorCode: ErrorCode.GENERAL,
          errorMessage: "rate limited by the relay-proxy",
        );
      default:
        return OfrepResult(
          errorCode: ErrorCode.GENERAL,
          errorMessage: _errorDetailsOrDefault(
            response.body,
            "request failed with status ${response.statusCode}",
          ),
        );
    }
  }

  OfrepResult _parseSuccess(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return OfrepResult(
        value: json["value"],
        reason: (json["reason"] as String?) ?? "STATIC",
        variant: json["variant"] as String?,
        metadata:
            (json["metadata"] as Map?)?.cast<String, dynamic>() ?? const {},
      );
    } on Object catch (e) {
      return OfrepResult(
        errorCode: ErrorCode.PARSE_ERROR,
        errorMessage: "error parsing OFREP response: $e",
      );
    }
  }

  OfrepResult _parseClientError(String body) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } on Object catch (e) {
      return OfrepResult(
        errorCode: ErrorCode.GENERAL,
        errorMessage: "error parsing OFREP error payload: $e",
      );
    }
    final errorCode = switch (json["errorCode"]) {
      "PARSE_ERROR" => ErrorCode.PARSE_ERROR,
      "TARGETING_KEY_MISSING" => ErrorCode.TARGETING_KEY_MISSING,
      "INVALID_CONTEXT" => ErrorCode.INVALID_CONTEXT,
      _ => ErrorCode.GENERAL,
    };
    return OfrepResult(
      errorCode: errorCode,
      errorMessage: (json["errorDetails"] as String?) ?? "evaluation error",
    );
  }

  String _errorDetailsOrDefault(String body, String fallback) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json["errorDetails"] is String) {
        return json["errorDetails"] as String;
      }
    } on Object {
      // Body wasn't JSON; fall through to the default message.
    }
    return fallback;
  }
}
