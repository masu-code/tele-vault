import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_background/flutter_background.dart';

/// Wraps `flutter_background`'s Android foreground service so bulk
/// uploads/downloads keep their network access while the app is
/// backgrounded (screen off, another app in front) instead of Android/MIUI
/// cutting the connection mid-transfer — the exact scenario that corrupted
/// a Telegram session mid-upload in practice (see TransferQueueNotifier).
///
/// Deliberately minimal: this keeps everything on the app's normal Dart
/// isolate (unlike plugins such as flutter_foreground_task, which run the
/// background work in a separate isolate and would require re-initializing
/// TelegramService/BackupRegistry/UploadService there). The persistent
/// notification's text can't be updated live once shown — real-time
/// progress stays in-app via TransferProgressBar; the notification's only
/// job is keeping the process alive and networked.
class BackgroundExecutionService {
  BackgroundExecutionService._();
  static final BackgroundExecutionService instance = BackgroundExecutionService._();

  bool _initialized = false;

  /// Shared in-flight init, so a caller that races ahead of [init] (e.g. the
  /// transfer queue starting moments after app launch, before main_shell's
  /// own unawaited init() call has finished the native round-trip/dialog)
  /// waits for the SAME attempt instead of silently no-op'ing on a stale
  /// `_initialized == false` and never actually starting the service.
  Future<void>? _initializing;

  /// Requests the permissions/setup needed for the foreground service.
  /// Safe to call multiple times/concurrently — later callers await the same
  /// in-flight attempt. No-op off Android.
  Future<void> init() {
    if (!Platform.isAndroid || _initialized) return Future.value();
    final inFlight = _initializing;
    if (inFlight != null) return inFlight;
    final future = _doInit();
    _initializing = future;
    return future;
  }

  Future<void> _doInit() async {
    try {
      final ok = await FlutterBackground.initialize(
        androidConfig: const FlutterBackgroundAndroidConfig(
          notificationTitle: 'TeleVault',
          notificationText: 'Syncing your photos and videos…',
          notificationImportance: AndroidNotificationImportance.normal,
        ),
      );
      _initialized = ok;
    } catch (e) {
      debugPrint('BackgroundExecutionService.init failed: $e');
    } finally {
      _initializing = null;
    }
  }

  /// Starts the foreground service, showing the persistent notification.
  /// Lazily awaits [init] if it hasn't completed yet — see [_initializing].
  Future<void> enable() async {
    if (!Platform.isAndroid) return;
    if (!_initialized) await init();
    if (!_initialized) return;
    if (FlutterBackground.isBackgroundExecutionEnabled) return;
    try {
      final ok = await FlutterBackground.enableBackgroundExecution();
      debugPrint('BackgroundExecutionService.enable: $ok');
    } catch (e) {
      debugPrint('BackgroundExecutionService.enable failed: $e');
    }
  }

  /// Stops the foreground service once there's no more queued work.
  Future<void> disable() async {
    if (!Platform.isAndroid) return;
    if (!FlutterBackground.isBackgroundExecutionEnabled) return;
    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (e) {
      debugPrint('BackgroundExecutionService.disable failed: $e');
    }
  }
}
