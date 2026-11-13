import 'package:flutter/foundation.dart' show debugPrint;
import '../../core/telegram/client.dart';

typedef CleanupStep = Future<void> Function();

/// What leaving a Telegram session involves, as injectable steps so the order
/// and the calls can be tested with fakes (see `AppSessionCleanup` in
/// providers/session_cleanup_provider.dart for the real ones).
///
/// [run] is shared by the user's "Log out" and by a confirmed revocation (the
/// server already dropped the session, so [serverLogOut] is skipped). Every
/// step is best effort: one failing never keeps the others from running, or
/// the user from reaching the login screen. Failures are logged by type only
/// (never a message, name, phone number or path).
///
/// The backup registry (`tv_registry.db`, pending-index rows included) is
/// deliberately NOT touched here: it stops the same account from uploading
/// its photos twice after logging back in. [bindAccount] decides what to do
/// with it once someone logs in again.
class SessionCleanup {
  const SessionCleanup({
    required this.stopTransfers,
    required this.cancelBackgroundTasks,
    required this.serverLogOut,
    required this.clearSession,
    required this.resetWorkers,
    required this.clearIndex,
    required this.resetAppState,
    required this.bindAccount,
    required this.resumeBackgroundTasks,
  });

  /// Only drops the session on this device: used where no UI/providers exist
  /// yet (and by tests that never log out).
  SessionCleanup.minimal()
      : stopTransfers = _noop,
        cancelBackgroundTasks = _noop,
        serverLogOut = _noop,
        clearSession = TelegramService.instance.clearSession,
        resetWorkers = _noop,
        clearIndex = _noop,
        resetAppState = _noop,
        bindAccount = _noBind,
        resumeBackgroundTasks = _noop;

  static Future<void> _noop() async {}
  static Future<void> _noBind(int userId) async {}

  /// 1a. Stops the upload/download queue (nothing new starts).
  final CleanupStep stopTransfers;

  /// 1b. Cancels the periodic and foreground WorkManager tasks.
  final CleanupStep cancelBackgroundTasks;

  /// 2. Telegram `auth.logOut` with a timeout, so the session also dies
  /// server-side. Must not throw.
  final CleanupStep serverLogOut;

  /// 3. [TelegramService.clearSession]: in-memory key, connection, session
  /// file.
  final CleanupStep clearSession;

  /// 3b. Makes the upload/download isolates drop the key they hold.
  final CleanupStep resetWorkers;

  /// 4. Clears the local index cache (not its backups) and resets the index
  /// notifier.
  final CleanupStep clearIndex;

  /// 4b. Per-account UI state (profile, ...).
  final CleanupStep resetAppState;

  /// After a login: ties the backup registry to [userId]; clears its links
  /// when that is a different account than the one it belonged to.
  final Future<void> Function(int userId) bindAccount;

  /// After a login: schedules the background backup again.
  final CleanupStep resumeBackgroundTasks;

  /// Steps 1 to 4 of leaving the session, in order. Navigating to the login
  /// screen (step 6) is the caller's: it flips the auth state afterwards.
  Future<void> run({required bool serverSide}) async {
    await _step('stop transfers', stopTransfers);
    await _step('cancel background tasks', cancelBackgroundTasks);
    if (serverSide) await _step('server log out', serverLogOut);
    await _step('clear session', clearSession);
    await _step('reset workers', resetWorkers);
    await _step('clear index', clearIndex);
    await _step('reset app state', resetAppState);
  }

  static Future<void> _step(String name, CleanupStep step) async {
    try {
      await step();
    } catch (e) {
      debugPrint('TVAUTH: log-out step "$name" failed (${e.runtimeType})');
    }
  }
}

/// Telegram `auth.logOut`, best effort: a failure or a timeout (offline, a
/// dead socket) only means the session stays alive on the server until the
/// user ends it from another device. Never throws.
Future<void> telegramServerLogOut({
  Duration timeout = const Duration(seconds: 8),
}) async {
  try {
    final result =
        await TelegramService.instance.call((c) => c.auth.logOut()).timeout(timeout);
    final error = result.error?.errorMessage;
    debugPrint('TVAUTH: auth.logOut ${error ?? 'ok'}');
  } catch (e) {
    debugPrint('TVAUTH: auth.logOut skipped (${e.runtimeType})');
  }
}
