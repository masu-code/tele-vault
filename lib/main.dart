import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:workmanager/workmanager.dart';
import 'app/app.dart';
import 'core/backup/headless_sync.dart';
import 'core/download/download_worker.dart';
import 'core/telegram/client.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // No permanent wakelock: keeping the screen on for the whole session made
  // the phone hot and throttled it. Background network on MIUI still needs the
  // user to disable battery restrictions for the app (requested at startup by
  // BackgroundExecutionService).

  // Cap the in-memory decoded-image cache so scrolling a large gallery can't
  // accumulate thousands of bitmaps and run out of memory.
  PaintingBinding.instance.imageCache
    ..maximumSize = 600
    ..maximumSizeBytes = 120 << 20; // 120 MB

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
  // The periodic task is only a cheap check with no notification; when files
  // are pending it schedules a one-off foreground run (headless_sync.dart).
  // `update` (not `keep`) so the registered spec always matches this code;
  // it keeps the existing schedule and never cancels a running run.
  // Only with a saved session: after "Log out" the tasks stay cancelled
  // across restarts, and a login schedules them again (see AuthNotifier).
  if (Platform.isAndroid) {
    unawaited(() async {
      await Workmanager().initialize(callbackDispatcher);
      if (await TelegramService.instance.hasSession()) {
        await scheduleHeadlessSync();
      } else {
        await cancelHeadlessSync();
      }
    }());
  }

  // Every Telegram download response is AES-decrypted in pure Dart on the
  // isolate that owns the connection; doing that on this one froze the UI
  // while browsing. Route downloads to their own isolate (see
  // download_worker.dart). Android only: that's where it was measured and
  // where the background-isolate plugin setup is exercised.
  if (Platform.isAndroid) {
    DownloadWorker.enabled = true;
  }

  runApp(const ProviderScope(child: TeleVaultApp()));
}
