import 'package:go_feature_flag/go_feature_flag.dart';
import 'package:openfeature_dart_server_sdk/evaluation_context.dart';
import 'package:openfeature_dart_server_sdk/open_feature_api.dart';

Future<void> main() async {
  final api = OpenFeatureAPI();
  await api.setProviderAndWait(
    GoFeatureFlagProvider(
      GoFeatureFlagOptions(endpoint: "http://localhost:1031"),
    ),
  );

  final client = api.getClient("my-app");
  final adminFlag = await client.getBooleanFlag(
    "flag-only-for-admin",
    defaultValue: false,
    context: EvaluationContext.immutable(
      targetingKey: "1d1b9238-2591-4a47-94cf-d2bc080892f1",
      attributes: {"admin": true},
    ),
  );
  print("flag-only-for-admin: $adminFlag");

  await api.shutdown();
}
