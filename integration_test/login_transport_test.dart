// On-device, real-network test of the login transport — the thing the user
// hit as "Connection problem" and, before that, as a code that arrived while
// the screen never moved.
//
// It deliberately submits a number Telegram will REJECT. That is the point:
// the round trip is exercised end to end (connect, DH handshake,
// initConnection, auth.sendCode, response) without consuming a real one-time
// code or touching a real account. A prompt PHONE_NUMBER_INVALID means the
// transport is healthy; "Connection problem" means it is not, which is
// exactly the failure under test.
//
// The device's saved session is backed up and restored around the run, so
// this never logs anyone out.
//
// Run:
//   flutter test integration_test/login_transport_test.dart -d <device>

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tele_vault/app/app.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// A syntactically well-formed number that cannot belong to anyone: +999 is
/// unassigned, so Telegram answers PHONE_NUMBER_INVALID instead of texting
/// a stranger.
const _unassignedNumber = '+9999 999-9999';

late final File _sessionFile;
String? _savedSession;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await WakelockPlus.enable();
    MediaKit.ensureInitialized();
    final dir = await getApplicationDocumentsDirectory();
    _sessionFile = File('${dir.path}/tele_vault_session.json');
    if (await _sessionFile.exists()) {
      _savedSession = await _sessionFile.readAsString();
      await _sessionFile.delete();
    }
  });

  tearDownAll(() async {
    final saved = _savedSession;
    if (saved != null) await _sessionFile.writeAsString(saved);
    await WakelockPlus.disable();
  });

  testWidgets('sendCode reaches Telegram and comes back with a real answer', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: TeleVaultApp()));

    // Wait out the startup session check and land on the phone screen.
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 60 && find.byType(TextField).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(
      find.byType(TextField),
      findsOneWidget,
      reason: 'expected the login phone-number field',
    );

    await tester.enterText(find.byType(TextField), _unassignedNumber);
    await tester.pump();
    await tester.tap(find.text('Send Code'));
    await tester.pump();

    // Poll for an answer. The whole point of the fix is that this resolves
    // from the server rather than from our own timeout, so give it more room
    // than the 45s auth timeout and then assert on WHICH answer arrived.
    final started = DateTime.now();
    String? shown;
    while (DateTime.now().difference(started) < const Duration(seconds: 75)) {
      await tester.pump(const Duration(milliseconds: 500));
      final errors = find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.style?.color == Colors.redAccent &&
            (w.data?.isNotEmpty ?? false),
      );
      if (errors.evaluate().isNotEmpty) {
        shown = tester.widget<Text>(errors.first).data;
        break;
      }
    }
    final elapsed = DateTime.now().difference(started);
    debugPrint('TVTEST: login answer after ${elapsed.inSeconds}s: $shown');

    expect(shown, isNotNull, reason: 'sendCode never produced any answer');
    // The whole assertion is "the server answered us", not which answer it
    // gave — a rejection (PHONE_NUMBER_INVALID) and a rate limit (FLOOD_WAIT)
    // are both proof the round trip completed. Only our own transport
    // failures are a fail.
    expect(
      shown,
      isNot(contains('Connection problem')),
      reason:
          'the request never completed a round trip — this is the reported bug',
    );
    expect(
      elapsed,
      lessThan(const Duration(seconds: 45)),
      reason: 'an answer that slow means we timed out rather than heard back',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
