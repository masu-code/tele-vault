import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/metadata/capture_date_recovery.dart';
import '../../../core/thumbnail/auto_maintenance_service.dart';
import '../../../core/thumbnail/auto_pack_service.dart';
import '../../../core/thumbnail/backfill_service.dart';
import '../../../core/thumbnail/thumb_prefetcher.dart' show ThumbPrefetcher;
import '../../../models/file_index.dart';
import '../../explorer/providers/index_provider.dart';
import '../../transfer/providers/transfer_queue_provider.dart';

/// The thumbnail backfill job, one per app process. Driven by the automatic
/// maintenance ([autoMaintenanceProvider]); there is no screen for it.
final backfillServiceProvider = Provider<BackfillService>(
  (ref) => BackfillService(index: RiverpodBackfillIndex(ref)),
);

/// The capture-date recovery job, one per app process like the backfill.
final captureDateRecoveryProvider = Provider<CaptureDateRecoveryService>(
  (ref) => CaptureDateRecoveryService(index: RiverpodBackfillIndex(ref)),
);

/// The jobs' view of the index: [indexProvider]'s state, written through
/// [IndexNotifier.applyAndSave] (the notifier's own serialized mutation path)
/// once the notifier is idle, so the app state holds the written index.
class RiverpodBackfillIndex implements BackfillIndexAccess {
  RiverpodBackfillIndex(this._ref);

  final Ref _ref;

  static const Duration _idleTimeout = Duration(minutes: 2);

  static bool _usable(IndexState s) =>
      !s.isLoading && !s.isSaving && s.error == null && !s.stale;

  @override
  FileIndex? current() {
    final s = _ref.read(indexProvider);
    return _usable(s) ? s.index : null;
  }

  @override
  Future<FileIndex> write(FileIndex Function(FileIndex current) mutate) async {
    final deadline = DateTime.now().add(_idleTimeout);
    while (!_usable(_ref.read(indexProvider))) {
      if (DateTime.now().isAfter(deadline)) {
        throw const BackfillException('The index stayed busy; run the backfill again later.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // Through the notifier's write chain: the mutation sees the index as it is
    // when its turn comes, so a user mutation queued meanwhile survives.
    return _ref.read(indexProvider.notifier).applyAndSave(mutate);
  }
}

/// The in-app automatic maintenance (packs, capture dates, backfill).
///
/// On Android the backfill (it downloads originals) never runs here: it runs
/// in the WorkManager maintenance task, whose constraints require an
/// unmetered network and charging. On desktop there is no metered network or
/// battery rule (as for the backfill job before), so it runs here in chunks
/// while the user is idle.
final autoMaintenanceProvider = Provider<AutoMaintenanceService>((ref) {
  final index = RiverpodBackfillIndex(ref);
  return AutoMaintenanceService(
    packer: AutoPackService(index: index),
    dates: ref.read(captureDateRecoveryProvider),
    backfill: ref.read(backfillServiceProvider),
    lock: MaintenanceLock.standard(),
    unmetered: () async => !Platform.isAndroid || await unmeteredNetwork(),
    charging: () async => !Platform.isAndroid,
    userBusy: () =>
        ref.read(transferQueueProvider).active ||
        ThumbPrefetcher.instance.status.value.queued > 0,
  );
});

/// Starts the automatic maintenance: once the index is synced with Telegram
/// on app start, and after every upload queue run. Read it once (the shell
/// does, after the first index load).
final autoMaintenanceBindingProvider = Provider<void>((ref) {
  final scheduler = MaintenanceScheduler(ref.read(autoMaintenanceProvider).runOnce);
  MaintenanceTriggers.register(scheduler.trigger);
  var synced = false;
  ref.listen<IndexState>(
    indexProvider,
    (_, s) {
      if (synced || s.isLoading || s.isSaving || s.error != null || s.stale) return;
      if (!ref.read(indexProvider.notifier).remoteSynced) return;
      synced = true;
      scheduler.trigger();
    },
    fireImmediately: true,
  );
  ref.onDispose(() {
    MaintenanceTriggers.register(null);
    scheduler.dispose();
  });
});
