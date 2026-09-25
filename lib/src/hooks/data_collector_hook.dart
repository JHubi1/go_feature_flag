import 'package:openfeature_dart_server_sdk/hooks.dart';

import '../data_collector_manager.dart';
import '../json_snapshot.dart';
import '../models/feature_event.dart';

const _cachedReason = "CACHED";
const _providerCacheSource = "PROVIDER_CACHE";

/// Records a `FeatureEvent` for each flag evaluation so it can be exported to
/// the relay-proxy data collector.
///
/// Mirrors the Go SDK's REMOTE-mode `hook.DataCollectorHook`: a *successful*
/// evaluation is only recorded when it was served from the client-side cache
/// (`reason == CACHED`), since every other REMOTE evaluation is already
/// recorded server-side by the relay-proxy itself. Evaluation errors are always
/// recorded, using the SDK default.
class DataCollectorHook extends BaseHook {
  DataCollectorHook(this._dataCollectorManager)
    : super(metadata: const HookMetadata(name: "DataCollectorHook"));

  final DataCollectorManager _dataCollectorManager;

  @override
  Future<void> after(HookContext context) async {
    final details = context.evaluationDetails;
    if (details == null || details.reason != _cachedReason) return;
    await _dataCollectorManager.addEvent(
      FeatureEvent(
        contextKind: _contextKind(context),
        userKey: _userKey(context),
        creationDate: _nowInSeconds(),
        key: context.flagKey,
        variation: details.variant ?? "",
        value: jsonSnapshot(context.result),
        isDefault: false,
        source: _providerCacheSource,
      ),
    );
  }

  @override
  Future<void> error(HookContext context) async {
    await _dataCollectorManager.addEvent(
      FeatureEvent(
        contextKind: _contextKind(context),
        userKey: _userKey(context),
        creationDate: _nowInSeconds(),
        key: context.flagKey,
        variation: "SdkDefault",
        value: jsonSnapshot(context.defaultValue),
        isDefault: true,
        source: _providerCacheSource,
      ),
    );
  }

  String _contextKind(HookContext context) =>
      context.evaluationContext["anonymous"] == true ? "anonymousUser" : "user";

  String _userKey(HookContext context) =>
      context.evaluationContext["targetingKey"] as String? ?? "undefined";

  int _nowInSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
