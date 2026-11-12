import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/app/app.dart';
import 'package:tele_vault/features/auth/providers/auth_provider.dart';
import 'package:tele_vault/features/auth/screens/otp_screen.dart';
import 'package:tele_vault/features/auth/screens/phone_screen.dart';

// The bug these pin down, reported as "meto numero, carga un poco y me
// regresa a la misma pantalla y ni siquiera envió el código":
//
// TeleVaultApp picked its root widget off `isLoading`. Tapping Send Code sets
// isLoading = true while step is still `initial`, so the root swapped to the
// startup splash, which tore down the Navigator AND the live PhoneScreen
// underneath it. When sendCode came back a moment later the screen that was
// listening for the result no longer existed, so nothing ever pushed the code
// screen — the user landed back on an empty phone field. (Device logs from
// that run showed `sendCode SUCCESS (+11217ms)` while the UI showed nothing.)
//
// `restoring` replaces `isLoading` for that decision: it is set exactly once,
// at the end of the cold-start session check.

(Widget, AuthNotifier) _app(AuthState initial) {
  final notifier = AuthNotifier.withoutRestore(initial);
  return (
    ProviderScope(
      overrides: [authProvider.overrideWith((ref) => notifier)],
      child: const TeleVaultApp(),
    ),
    notifier,
  );
}

void main() {
  testWidgets('the splash shows only while the cold-start restore runs', (
    tester,
  ) async {
    final (app, notifier) = _app(const AuthState(isLoading: true));
    await tester.pumpWidget(app);
    expect(find.byType(PhoneScreen), findsNothing);

    notifier.debugSetState(const AuthState(restoring: false));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneScreen), findsOneWidget);
  });

  testWidgets('sending a code does NOT tear down the PhoneScreen', (
    tester,
  ) async {
    final (app, notifier) = _app(const AuthState(restoring: false));
    await tester.pumpWidget(app);
    final before = tester.state(find.byType(PhoneScreen));

    // Exactly what sendCode does first: isLoading true, step still initial.
    notifier.debugSetState(
      const AuthState(restoring: false, isLoading: true),
    );
    // pump, not pumpAndSettle: the Send Code button shows a spinner while
    // isLoading is true, and that animation never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(PhoneScreen), findsOneWidget);
    expect(
      tester.state(find.byType(PhoneScreen)),
      same(before),
      reason: 'a rebuilt PhoneScreen loses the listener waiting for the code',
    );
  });

  testWidgets('a code arriving pushes the OTP screen', (tester) async {
    final (app, notifier) = _app(const AuthState(restoring: false));
    await tester.pumpWidget(app);

    notifier.debugSetState(
      const AuthState(restoring: false, isLoading: true),
    );
    // pump, not pumpAndSettle: the Send Code button shows a spinner while
    // isLoading is true, and that animation never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    notifier.debugSetState(
      const AuthState(
        restoring: false,
        step: AuthStep.waitingCode,
        phoneNumber: '+584125551234',
        phoneCodeHash: 'hash',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OtpScreen), findsOneWidget);
    expect(find.textContaining('+584125551234'), findsOneWidget);
  });

  testWidgets('a later error does not stack a second OTP screen', (
    tester,
  ) async {
    final (app, notifier) = _app(const AuthState(restoring: false));
    await tester.pumpWidget(app);
    notifier.debugSetState(
      const AuthState(
        restoring: false,
        step: AuthStep.waitingCode,
        phoneNumber: '+584125551234',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OtpScreen), findsOneWidget);

    // A failed signIn keeps step == waitingCode and adds an error.
    notifier.debugSetState(
      const AuthState(
        restoring: false,
        step: AuthStep.waitingCode,
        phoneNumber: '+584125551234',
        error: "That code isn't right. Check it and try again.",
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OtpScreen), findsOneWidget);
  });

  testWidgets('login screens survive a short landscape viewport', (
    tester,
  ) async {
    // The device screenshot of the login screen in landscape came back with
    // Flutter's overflow stripes across the Send Code button.
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final (app, _) = _app(const AuthState(restoring: false));
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Send Code'), findsOneWidget);
  });
}
