import 'package:connectivity_plus/connectivity_plus.dart';
import 'backup_registry.dart';

/// True when automatic backup is allowed to run right now: always on
/// WiFi/ethernet, on mobile data only if the user opted in via
/// [BackupRegistry.allowMobileData]. Shared by the live in-app sync
/// ([BackupNotifier]) and the headless periodic background task
/// ([runHeadlessSync]) so both follow the same rule.
Future<bool> hasUsableConnection() async {
  final results = await Connectivity().checkConnectivity();
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return true;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return BackupRegistry.instance.allowMobileData;
  }
  return false;
}
