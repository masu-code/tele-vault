// Integration tests that run ON the real device against the REAL Telegram
// network, reproducing the production failure: MIUI silently kills the idle TCP
// socket, and a download/upload/index operation then hits a dead socket. With
// the fix (TelegramService.call → reconnect), every operation must recover
// transparently instead of throwing SocketDeadException.
//
// The session is injected at runtime via --dart-define (base64 of a
// previously-captured tele_vault_session.json) so credentials never live in the
// repo, and so the test survives flutter's uninstall-after-run. WakelockPlus is
// enabled to keep the screen on — MIUI cuts an app's network in Doze, so the
// device must stay awake for the duration.
//
// Run (PowerShell helper writes the full command):
//   flutter test integration_test/reconnect_test.dart -d <device> \
//     --dart-define=TV_SESSION_B64=<base64 of session json>

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tele_vault/core/download/download_service.dart';
import 'package:tele_vault/core/index/index_service.dart';
import 'package:tele_vault/core/telegram/client.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _sessionB64 = String.fromEnvironment('TV_SESSION_B64');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Keep the device awake; MIUI Doze otherwise starves the app of network.
    await WakelockPlus.enable();

    // Inject the captured session into the sandbox so restoreSession() works
    // without an interactive login (and survives flutter's post-run uninstall).
    expect(_sessionB64.isNotEmpty, isTrue,
        reason: 'Pass --dart-define=TV_SESSION_B64=<base64 of session json>');
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/tele_vault_session.json');
    await f.writeAsString(utf8.decode(base64.decode(_sessionB64)));
  });

  tearDownAll(() async {
    await WakelockPlus.disable();
  });

  Future<void> ensureConnected() async {
    if (!TelegramService.instance.isConnected) {
      final restored = await TelegramService.instance.restoreSession();
      expect(restored, isTrue, reason: 'Session injection failed.');
    }
  }

  group('reconnect on dead socket — real device, real Telegram', () {
    testWidgets('session is restored from injected file', (tester) async {
      final restored = await TelegramService.instance.restoreSession();
      expect(restored, isTrue);
      expect(TelegramService.instance.isConnected, isTrue);
    });

    testWidgets('index loads normally (baseline)', (tester) async {
      await ensureConnected();
      final index = await IndexService.instance.load();
      expect(index.version, greaterThan(0));
    });

    testWidgets('index load RECOVERS after the socket is killed',
        (tester) async {
      await ensureConnected();
      await IndexService.instance.load(); // warm up a live socket

      TelegramService.instance.debugKillSocket(); // simulate MIUI

      final index = await IndexService.instance.load();
      expect(index.version, greaterThan(0));
    });

    testWidgets('file download RECOVERS after the socket is killed',
        (tester) async {
      await ensureConnected();
      final index = await IndexService.instance.load();

      final files = [...index.files]
        ..sort((a, b) => a.totalSize.compareTo(b.totalSize));
      if (files.isEmpty) {
        // ignore: avoid_print
        print('SKIP: vault has no files to download.');
        return;
      }
      final target = files.first;

      TelegramService.instance.debugKillSocket(); // simulate MIUI

      final file = await DownloadService.instance.downloadToCache(target);
      final len = await file.length();
      expect(len, equals(target.totalSize),
          reason: 'Downloaded file must be complete after reconnect.');
    });

    testWidgets('two consecutive kills both recover', (tester) async {
      await ensureConnected();

      TelegramService.instance.debugKillSocket();
      final a = await IndexService.instance.load();
      expect(a.version, greaterThan(0));

      TelegramService.instance.debugKillSocket();
      final b = await IndexService.instance.load();
      expect(b.version, greaterThan(0));
    });
  });
}
