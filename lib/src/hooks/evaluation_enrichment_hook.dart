import 'package:openfeature_dart_server_sdk/hooks.dart';

/// Merges [exporterMetadata] into the evaluation context under
/// `gofeatureflag.exporterMetadata` before each evaluation, mirroring the Go
/// SDK's `hook.EvaluationEnrichmentHook`.
///
/// The relay-proxy reads this to tag exported evaluation/tracking events with
/// metadata about the caller.
class EvaluationEnrichmentHook extends BaseHook {
  EvaluationEnrichmentHook(this.exporterMetadata)
    : super(metadata: const HookMetadata(name: "EvaluationEnrichmentHook"));

  /// Metadata merged into every evaluation context under
  /// `gofeatureflag.exporterMetadata`.
  final Map<String, dynamic> exporterMetadata;

  @override
  Future<Map<String, dynamic>?> before(HookContext context) async {
    final existing = context.evaluationContext["gofeatureflag"];
    final goffContext = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    goffContext["exporterMetadata"] = exporterMetadata;
    return {"gofeatureflag": goffContext};
  }
}
