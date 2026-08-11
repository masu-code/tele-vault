import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:workmanager/workmanager.dart';
import 'app/app.dart';
import 'core/backup/headless_sync.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // MIUI/Xiaomi aggressively dozes the app and cuts its network the moment the
  // screen dims, which makes Telegram connections time out mid-use. Keeping the
  // screen awake while the app is in the foreground avoids that. (Background
  // network still needs the user to disable battery restrictions for the app.)
  if (Platform.isAndroid || Platform.isIOS) {
    WakelockPlus.enable();
  }

  // Cap the in-memory decoded-image cache so scrolling a large gallery can't
  // accumulate thousands of bitmaps and run out of memory.
  PaintingBinding.instance.imageCache
    ..maximumSize = 200
    ..maximumSizeBytes = 100 << 20; // 100 MB

  // Required for in-app video playback (Windows + Android).
  MediaKit.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Lets pending uploads in backup-enabled albums keep landing even if
  // TeleVault is never opened (or is fully closed) after they're taken —
  // matches how Google Photos and similar apps back up in the background
  // regardless of whether their UI has ever been launched since. Android
  // won't run this more often than every ~15 minutes; see headless_sync.dart
  // for what the task itself does and why that's an acceptable trade-off.
  if (Platform.isAndroid) {
    unawaited(() async {
      await Workmanager().initialize(callbackDispatcher);
      await Workmanager().registerPeriodicTask(
        uploadSyncTaskName,
        uploadSyncTaskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    }());
  }

  runApp(const ProviderScope(child: TeleVaultApp()));
}
