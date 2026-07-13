// Diagnoses whether PhotoManager.editor.deleteWithIds actually removes a
// file on this device/OS (Android 11+ scoped storage), independent of any
// tap in our own UI. This does NOT reproduce the "delete someone else's
// media" consent-dialog path (deleting an asset the app didn't create always
// requires a system dialog, which no automation on this MIUI device can
// tap — adb input is blocked, and integration_test's WidgetTester can't
// reach system-level windows either). It only proves whether the plugin's
// method-channel plumbing to Android's MediaStore delete API works at all,
// for a file this app owns (no dialog needed for self-owned files).
//
// Run:
//   flutter test integration_test/photo_delete_test.dart -d <device>

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photo_manager/photo_manager.dart';

// A minimal valid 1x1 red PNG.
final _tinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
  0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('deleteWithIds removes a self-created asset from MediaStore',
      (tester) async {
    final permission = await PhotoManager.requestPermissionExtend();
    expect(permission.hasAccess, isTrue, reason: 'Photo permission must already be granted.');

    final saved = await PhotoManager.editor.saveImage(
      _tinyPng,
      filename: 'televault_delete_diag.png',
      relativePath: 'Pictures',
    );
    // ignore: avoid_print
    print('DIAG: created asset id=${saved.id}');

    final beforeDelete = await AssetEntity.fromId(saved.id);
    expect(beforeDelete, isNotNull, reason: 'Sanity check: the created asset must be findable.');

    final deletedIds = await PhotoManager.editor.deleteWithIds([saved.id]);
    // ignore: avoid_print
    print('DIAG: deleteWithIds returned $deletedIds');

    final afterDelete = await AssetEntity.fromId(saved.id);
    // ignore: avoid_print
    print('DIAG: asset still findable after delete? ${afterDelete != null}');

    expect(deletedIds, contains(saved.id),
        reason: 'deleteWithIds should report this id as deleted.');
    expect(afterDelete, isNull,
        reason: 'The asset must actually be gone from MediaStore after deletion.');
  });
}
