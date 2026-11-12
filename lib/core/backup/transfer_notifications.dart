import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../upload/upload_service.dart' show logSafeError;

/// The system-notification progress bar for uploads/downloads, so it's visible
/// that TeleVault is working while the app is in the background or closed.
///
/// Used from both the app (via the transfer queue's state) and the headless
/// WorkManager task, each in its own engine — so it initialises itself lazily
/// and never throws: a notification problem must not break a transfer.
class TransferNotifications {
  TransferNotifications._();
  static final instance = TransferNotifications._();

  /// The progress notification. The headless backup's foreground service
  /// (see headless_sync.dart) uses the same id and channel, so its progress
  /// updates replace the service notification instead of adding a second one.
  static const progressId = 4217;
  static const channelId = 'televault_transfers';
  static const channelName = 'Backup progress';

  /// The dismissible result line ([showDone]). Separate from [progressId]:
  /// when a foreground service holds [progressId], the system removes that
  /// notification as the service stops, which would take the result with it.
  static const doneId = 4218;

  static const _id = progressId;
  static const _channelId = channelId;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  DateTime? _lastUpdate;

  /// Android throttles apps that post notification updates too often, silently
  /// dropping some — which would freeze the bar mid-upload.
  static const _minInterval = Duration(milliseconds: 1500);

  Future<void> init() async {
    if (!Platform.isAndroid || _ready) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('TransferNotifications.init failed: ${logSafeError(e)}');
    }
  }

  /// Android 13+ keeps notifications off until the user grants this at
  /// runtime; without it nothing here (and not even the foreground-service
  /// notification) is shown.
  Future<void> requestPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await init();
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('TransferNotifications.requestPermission failed: ${logSafeError(e)}');
    }
  }

  /// Shows/updates the ongoing progress notification. [done] files finished
  /// out of [total], with [current] (0..1) of the file in flight.
  Future<void> showProgress({
    required String title,
    required String body,
    required int done,
    required int total,
    double current = 0,
    bool force = false,
  }) async {
    if (!Platform.isAndroid) return;
    final now = DateTime.now();
    final last = _lastUpdate;
    if (!force && last != null && now.difference(last) < _minInterval) return;
    _lastUpdate = now;
    try {
      await init();
      if (!_ready) return;
      final fraction = total <= 0 ? 0.0 : ((done + current) / total).clamp(0.0, 1.0);
      await _plugin.show(
        _id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            channelName,
            channelDescription: 'Progress of photo/video uploads and downloads',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            playSound: false,
            enableVibration: false,
            showWhen: false,
            showProgress: true,
            maxProgress: 100,
            progress: (fraction * 100).round(),
            indeterminate: total <= 0,
            icon: '@mipmap/ic_launcher',
          ),
        ),
      );
    } catch (e) {
      debugPrint('TransferNotifications.showProgress failed: ${logSafeError(e)}');
    }
  }

  /// Shows a short, dismissible result line (its own id, [doneId]); callers
  /// [cancel] the progress notification first.
  Future<void> showDone(String text) async {
    if (!Platform.isAndroid) return;
    _lastUpdate = null;
    try {
      await init();
      if (!_ready) return;
      await _plugin.show(
        doneId,
        'TeleVault',
        text,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            channelName,
            channelDescription: 'Progress of photo/video uploads and downloads',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: false,
            autoCancel: true,
            playSound: false,
            enableVibration: false,
            icon: '@mipmap/ic_launcher',
          ),
        ),
      );
    } catch (e) {
      debugPrint('TransferNotifications.showDone failed: ${logSafeError(e)}');
    }
  }

  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    _lastUpdate = null;
    try {
      await init();
      if (_ready) await _plugin.cancel(_id);
    } catch (e) {
      debugPrint('TransferNotifications.cancel failed: ${logSafeError(e)}');
    }
  }
}
