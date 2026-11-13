import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/headless_sync.dart';
import '../../../core/download/download_worker.dart';
import '../../../core/telegram/client.dart';
import '../../../core/thumbnail/maintenance_state_reset.dart';
import '../../../core/upload/upload_worker.dart';
import '../../explorer/providers/index_provider.dart';
import '../../profile/providers/profile_provider.dart';
import '../../transfer/providers/transfer_queue_provider.dart';
import '../session_cleanup.dart';

/// The app's real [SessionCleanup]: the providers and singletons the steps
/// act on are read lazily, when a step runs.
final sessionCleanupProvider = Provider<SessionCleanup>((ref) => SessionCleanup(
      stopTransfers: () async => ref.read(transferQueueProvider.notifier).cancel(),
      cancelBackgroundTasks: cancelHeadlessSync,
      serverLogOut: telegramServerLogOut,
      clearSession: TelegramService.instance.clearSession,
      resetWorkers: () async {
        UploadWorker.instance.resetSession();
        DownloadWorker.instance.resetSession();
      },
      clearIndex: () => ref.read(indexProvider.notifier).clearForLogout(),
      resetAppState: () async => ref.read(profileProvider.notifier).reset(),
      bindAccount: (userId) async {
        final binding = await BackupRegistry.instance.bindAccount(userId);
        // The enum name only: never the account id.
        debugPrint('TVAUTH: backup registry bound to the account (${binding.name})');
        if (binding == AccountBinding.switched) {
          // The previous account's pack/backfill/date bookkeeping holds
          // message ids that mean something else here. Local files only.
          final n = await clearMaintenanceStateForAccountSwitch();
          debugPrint('TVAUTH: maintenance state cleared ($n files)');
        }
      },
      resumeBackgroundTasks: scheduleHeadlessSync,
    ));
