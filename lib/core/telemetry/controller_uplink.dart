import '../app_controller.dart';
import 'perf_telemetry.dart';

/// Sends telemetry reports with the signed-in session of [controller].
class ControllerPerfUplink implements PerfUplink {
  ControllerPerfUplink(this.controller);
  final AppController controller;

  @override
  bool get isDemo => controller.isDemo;
  @override
  bool get hasAccess => controller.hasAccess;
  // A synced (or cached) snapshot carries the server's feature list.
  @override
  bool get featuresKnown => controller.lastSync != null;
  @override
  bool supports(String feature) => controller.supports(feature);
  @override
  Future<void> send(Map<String, Object?> report) async {
    await controller.remote('/telemetry/perf', method: 'POST', body: report);
  }
}
