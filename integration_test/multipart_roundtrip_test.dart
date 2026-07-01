// Validates the >2GB-file split/reassembly path end-to-end against the REAL
// Telegram network, without actually uploading gigabytes of data: it forces a
// small file through the same multi-segment code path by overriding the
// segment-size threshold, then verifies the downloaded file is byte-for-byte
// identical to the original.
//
// This exists because a refactor to parallelize chunk downloads introduced a
// bug where a document's own (0-based) byte offsets were used directly as the
// position to write into the reassembled output file, instead of being offset
// by how many bytes prior parts had already contributed — silently corrupting
// any file split into more than one Telegram document. Single-part files (the
// overwhelming majority in manual testing) never exercised this path, so it
// went unnoticed until reviewed for this test.
//
// Run (PowerShell helper writes the full command):
//   flutter test integration_test/multipart_roundtrip_test.dart -d <device> \
//     --dart-define=TV_SESSION_B64=<base64 of session json>

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tele_vault/core/download/download_service.dart';
import 'package:tele_vault/core/index/index_service.dart';
import 'package:tele_vault/core/telegram/client.dart';
import 'package:tele_vault/core/upload/upload_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _sessionB64 = String.fromEnvironment('TV_SESSION_B64');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await WakelockPlus.enable();
    expect(_sessionB64.isNotEmpty, isTrue,
        reason: 'Pass --dart-define=TV_SESSION_B64=<base64 of session json>');
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/tele_vault_session.json');
    await f.writeAsString(utf8.decode(base64.decode(_sessionB64)));
  });

  tearDownAll(() async {
    await WakelockPlus.disable();
  });

  testWidgets('multi-segment file uploads and downloads byte-for-byte intact',
      (tester) async {
    if (!TelegramService.instance.isConnected) {
      final restored = await TelegramService.instance.restoreSession();
      expect(restored, isTrue, reason: 'Session injection failed.');
    }

    // 5 MB of deterministic pseudo-random bytes, forced into 2 MB segments —
    // 3 Telegram documents (2 + 2 + 1 MB) exercising the exact reassembly path
    // real >1.9GB files use, for a fraction of the data.
    final rand = Random(42);
    final original = Uint8List(5 * 1024 * 1024);
    for (var i = 0; i < original.length; i++) {
      original[i] = rand.nextInt(256);
    }
    final tmp = await getTemporaryDirectory();
    final srcDir = Directory(p.join(tmp.path, 'multipart_test'));
    await srcDir.create(recursive: true);
    final srcFile = File(p.join(srcDir.path, 'multipart_source.bin'));
    await srcFile.writeAsBytes(original);

    final fileItem = await UploadService.instance.uploadFile(
      srcFile,
      maxSegmentSizeOverride: 2 * 1024 * 1024,
    );
    addTearDown(() async {
      await IndexService.instance.deleteFromTelegram([fileItem]);
    });

    expect(fileItem.parts.length, equals(3),
        reason: '5MB file with a 2MB segment cap must split into 3 parts.');
    expect(fileItem.totalSize, equals(original.length));

    final destDir = Directory(p.join(tmp.path, 'multipart_test_out'));
    await destDir.create(recursive: true);
    final downloaded = await DownloadService.instance.downloadFile(
      fileItem,
      destDir: destDir.path,
    );

    final downloadedBytes = await downloaded.readAsBytes();
    expect(downloadedBytes.length, equals(original.length),
        reason: 'Downloaded file size must match the original exactly.');
    expect(downloadedBytes, equals(original),
        reason: 'Downloaded bytes must be identical to what was uploaded — '
            'a mismatch means parts were reassembled in the wrong positions.');
  });
}
