import 'dart:collection';
import 'dart:convert';

import 'ofrep_client.dart';

/// A TTL + LRU (least-recently-used) cache of OFREP evaluation results, keyed
/// by flag key and evaluation context.
///
/// Mirrors the Go SDK's client-side cache used to reduce network calls in
/// REMOTE mode.
class EvaluationCache {
  EvaluationCache({
    required this.maxSize,
    required this.ttl,
    required this.disabled,
  });

  /// Maximum number of entries retained before the oldest is evicted.
  final int maxSize;

  /// A negative duration means entries never expire (mirrors the Go SDK's
  /// `FlagCacheTTL: -1` convention).
  final Duration ttl;

  /// Whether caching is disabled; when `true`, [get] and [set] are no-ops.
  final bool disabled;

  final LinkedHashMap<String, _CacheEntry> _entries = LinkedHashMap();

  /// The cached result for [flagKey] and [context], or `null` on a cache miss,
  /// an expired entry, or when [disabled].
  OfrepResult? get(String flagKey, Map<String, dynamic> context) {
    if (disabled || maxSize <= 0) return null;
    final key = _keyFor(flagKey, context);
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (entry.expiresAt != null && DateTime.now().isAfter(entry.expiresAt!)) {
      return null;
    }
    _entries[key] = entry; // reinsert as most-recently-used
    return entry.result;
  }

  /// Stores [result] for [flagKey] and [context], evicting the
  /// least-recently-used entry first if [maxSize] has been reached.
  void set(String flagKey, Map<String, dynamic> context, OfrepResult result) {
    if (disabled || maxSize <= 0) return;
    final key = _keyFor(flagKey, context);
    _entries.remove(key);
    if (_entries.length >= maxSize) {
      _entries.remove(_entries.keys.first);
    }
    final expiresAt = ttl.isNegative ? null : DateTime.now().add(ttl);
    _entries[key] = _CacheEntry(result, expiresAt);
  }

  /// Removes every cached entry.
  void clear() => _entries.clear();

  String _keyFor(String flagKey, Map<String, dynamic> context) {
    final sortedKeys = context.keys.toList()..sort();
    final canonical = {for (final k in sortedKeys) k: context[k]};
    return "$flagKey::${jsonEncode(canonical)}";
  }
}

class _CacheEntry {
  _CacheEntry(this.result, this.expiresAt);

  final OfrepResult result;
  final DateTime? expiresAt;
}
