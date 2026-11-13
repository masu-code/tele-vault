import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/auth/providers/auth_provider.dart';
import '../features/auth/screens/api_credentials_screen.dart';
import '../features/auth/screens/phone_screen.dart';
import '../features/shell/main_shell.dart';

/// Lets the app clear the route stack without a BuildContext (a revocation
/// arrives from anywhere, with the account sheet or a viewer on screen).
final _navigatorKey = GlobalKey<NavigatorState>();

class TeleVaultApp extends ConsumerWidget {
  const TeleVaultApp({super.key, @visibleForTesting this.debugSignedInHome});

  /// Test-only: stands in for [MainShell] (which needs the device plugins).
  final Widget? debugSignedInHome;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);

    // Leaving the signed-in state (log out, revoked session): MaterialApp
    // swaps its home for the login screen, but every route pushed on top of
    // the old home (account sheet, viewers, settings screens) would stay on
    // top of it. Pop back to the root route so the login screen is what shows.
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (previous?.isAuthenticated == true && !next.isAuthenticated) {
        _navigatorKey.currentState?.popUntil((r) => r.isFirst);
      }
    });

    // AuthNotifier starts at AuthStep.initial and only flips to authenticated
    // once restoring the saved session resolves — without this branch, an
    // already-logged-in user saw the phone-number entry screen flash for a
    // moment on every cold start before the real MainShell took over.
    //
    // This reads AuthState.restoring, which is set exactly once per launch.
    // It used to read `isLoading`, which is also true during sendCode/signIn
    // — so tapping Send Code swapped this root widget to the splash, tore
    // down the Navigator along with the PhoneScreen that was waiting for the
    // result, and login silently bounced back to an empty phone field.
    final stillChecking = auth.restoring;

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'TeleVault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF2AABEE),
          surface: Color(0xFF1C1C1E),
        ),
      ),
      // Checked before anything session-related: an install with no saved
      // api_id/api_hash yet has nothing to restore in the first place (see
      // AuthNotifier._init), so this always wins over `restoring`/
      // `isAuthenticated` regardless of their values.
      home: auth.needsApiCredentials
          ? const ApiCredentialsScreen()
          : auth.isAuthenticated
          ? (debugSignedInHome ?? const MainShell())
          : stillChecking
          ? const _StartupSplash()
          : const PhoneScreen(),
    );
  }
}

/// Shown only while [AuthNotifier] is restoring a saved session on cold
/// start — same branding as [PhoneScreen] so there's nothing to flash
/// between this and either of the two screens it resolves to.
class _StartupSplash extends StatelessWidget {
  const _StartupSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Icon(Icons.cloud_outlined, size: 56, color: Color(0xFF2AABEE)),
      ),
    );
  }
}
