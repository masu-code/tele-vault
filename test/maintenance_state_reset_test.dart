import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tele_vault/core/thumbnail/maintenance_state_reset.dart';

void main() {
  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('maint_reset_test');
  });
  tearDown(() async {
    try {
      await support.delete(recursive: true);
    } catch (_) {}
  });

  File f(String rel) => File(p.joinAll([support.path, ...rel.split('/')]))
    ..createSync(recursive: true)
    ..writeAsStringSync('x');

  test('an account switch deletes the previous account\'s maintenance state only', () async {
    final gone = [
      f('backfill_state.json'),
      f('backfill_produced.log'),
      f('auto_pack/backfill_state.json'),
      f('auto_pack/backfill_produced.log'),
      f('televault_thumbs/_packs_covered.json'),
      f('televault_thumbs/_packs_applied.json'),
      f('capture_date_recovery.json'),
    ];
    final kept = [
      f('televault_thumbs/abc.jpg'),
      f('index_cache.json'),
      f('tv_registry.db'),
      f('index_backups/20261111T000000000Z-0000.json'),
    ];
    final n = await clearMaintenanceStateForAccountSwitch(supportDir: support);
    expect(n, gone.length);
    for (final e in gone) {
      expect(e.existsSync(), isFalse, reason: p.basename(e.path));
    }
    for (final e in kept) {
      expect(e.existsSync(), isTrue, reason: p.basename(e.path));
    }
  });

  test('nothing to delete is fine, and a missing directory never throws', () async {
    expect(await clearMaintenanceStateForAccountSwitch(supportDir: support), 0);
    expect(
      await clearMaintenanceStateForAccountSwitch(
          supportDir: Directory(p.join(support.path, 'does', 'not', 'exist'))),
      0,
    );
  });
}
