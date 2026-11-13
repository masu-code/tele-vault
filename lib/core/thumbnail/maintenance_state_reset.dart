import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../metadata/capture_date_recovery.dart';
import 'backfill_state.dart';
import 'pack_coverage.dart';

/// Deletes the local background-maintenance bookkeeping that belongs to the
/// previous account, after `BackupRegistry.bindAccount` reports
/// `AccountBinding.switched`. Message ids in these files mean something else
/// in the new account, so they must not be applied to its index:
///
/// - `backfill_state.json` and its `backfill_produced.log` journal;
/// - the auto-pack state (`auto_pack/`: the same two files);
/// - `_packs_covered.json` and `_packs_applied.json` in the thumbnail dir;
/// - `capture_date_recovery.json`.
///
/// Local files only: nothing on Telegram is touched, and the thumbnails
/// themselves stay (they are keyed by file id, not by account). Never throws;
/// returns how many files were deleted.
Future<int> clearMaintenanceStateForAccountSwitch({
  Directory? supportDir,
  Directory? thumbDir,
}) async {
  var deleted = 0;
  Future<void> drop(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        deleted++;
      }
    } catch (_) {}
  }

  try {
    final support = supportDir ?? await getApplicationSupportDirectory();
    final thumbs = thumbDir ?? Directory(p.join(support.path, 'televault_thumbs'));
    for (final dir in [support.path, p.join(support.path, 'auto_pack')]) {
      await drop(p.join(dir, BackfillStateStore.stateFileName));
      await drop(p.join(dir, BackfillStateStore.journalFileName));
    }
    await drop(p.join(thumbs.path, PackCoverage.fileName));
    await drop(p.join(thumbs.path, '_packs_applied.json'));
    await drop(p.join(support.path, CaptureRecoveryStateStore.fileName));
  } catch (_) {}
  return deleted;
}
