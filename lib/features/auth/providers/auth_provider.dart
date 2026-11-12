import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;
import '../../../core/api_credentials_service.dart';
import '../../../core/telegram/client.dart';
import '../../../core/telegram/io_socket.dart';

enum AuthStep { initial, waitingCode, waitingPassword, authenticated }

class AuthState {
  final AuthStep step;
  final String? phoneNumber;
  final String? phoneCodeHash;
  final t.AccountPassword? accountPassword;
  final bool isLoading;
  final String? error;

  /// True only while the cold-start session restore is still running. This is
  /// deliberately NOT the same thing as [isLoading]: the app picks its root
  /// widget off this flag, and using [isLoading] for it meant every Send Code
  /// tap (isLoading true, step still initial) swapped the root out from under
  /// the live PhoneScreen. That tore down the Navigator mid-request, so when
  /// sendCode came back with a code on its way, the screen that was listening
  /// for it no longer existed — login just bounced back to an empty phone
  /// field with no code screen and no error.
  final bool restoring;

  /// True until this install has its own Telegram api_id/api_hash saved —
  /// see [ApiCredentialsService]. The app shows [ApiCredentialsScreen] for
  /// this instead of anything session-related; it's checked first, before
  /// [restoring] even starts a session-restore attempt.
  final bool needsApiCredentials;

  const AuthState({
    this.step = AuthStep.initial,
    this.phoneNumber,
    this.phoneCodeHash,
    this.accountPassword,
    this.isLoading = false,
    this.error,
    this.restoring = true,
    this.needsApiCredentials = false,
  });

  bool get isAuthenticated => step == AuthStep.authenticated;

  AuthState copyWith({
    AuthStep? step,
    String? phoneNumber,
    String? phoneCodeHash,
    t.AccountPassword? accountPassword,
    bool? isLoading,
    String? error,
    bool? restoring,
    bool? needsApiCredentials,
  }) => AuthState(
    step: step ?? this.step,
    phoneNumber: phoneNumber ?? this.phoneNumber,
    phoneCodeHash: phoneCodeHash ?? this.phoneCodeHash,
    accountPassword: accountPassword ?? this.accountPassword,
    isLoading: isLoading ?? this.isLoading,
    error: error,
    restoring: restoring ?? this.restoring,
    needsApiCredentials: needsApiCredentials ?? this.needsApiCredentials,
  );
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState()) {
    _init();
  }

  /// Test-only: starts at [initial] and skips the cold-start session restore,
  /// so widget tests can drive the auth state without touching the network.
  @visibleForTesting
  AuthNotifier.withoutRestore(AuthState initial) : super(initial);

  /// Test-only: pushes an arbitrary state through, for driving the screens
  /// that react to it.
  @visibleForTesting
  void debugSetState(AuthState next) => state = next;

  Future<void> _init() async {
    await ApiCredentialsService.instance.init();
    if (!ApiCredentialsService.instance.hasCredentials) {
      // Nothing to restore — without an api_id/api_hash there was never a
      // way for this install to have logged in before. Skip straight past
      // session restore instead of letting TelegramService.connect() run
      // with no credentials to hand it.
      state = state.copyWith(restoring: false, needsApiCredentials: true);
      return;
    }
    try {
      await _restoreSavedSession();
    } finally {
      // However that turned out, the cold-start check is over. This must run
      // on every path: the app shows a splash while `restoring` is true, so
      // leaving it set would freeze the launch on the splash forever.
      // copyWith clears `error` unless it's passed, and the expired-session
      // message set below has to survive.
      state = state.copyWith(
        restoring: false,
        isLoading: false,
        error: state.error,
      );
    }
  }

  /// Called once [ApiCredentialsScreen] has saved this install's
  /// credentials. There is nothing to restore yet (a fresh install can't
  /// have a saved session without credentials to have logged in with in the
  /// first place) — just clears the gate so the app moves on to the normal
  /// phone-number screen.
  void credentialsSaved() {
    state = state.copyWith(needsApiCredentials: false, restoring: false);
  }

  Future<void> _restoreSavedSession() async {
    state = state.copyWith(isLoading: true);
    // The first connect can fail because MIUI starves the app of network right
    // after launch (Doze). Retry a few times. Crucially, NEVER clear the saved
    // session on a transport failure — that would force a full re-login (phone
    // + OTP + 2FA) just because the network blinked. The session is only wiped
    // when the server actually rejects it (handled elsewhere).
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        debugPrint('TVAUTH: _init attempt $attempt');
        final restored = await TelegramService.instance.restoreSession();
        debugPrint('TVAUTH: _init restored=$restored');
        if (!restored) {
          state = state.copyWith(step: AuthStep.initial, isLoading: false);
          return;
        }

        // restoreSession only loads the saved key and opens a socket — it
        // never asks Telegram whether that key is still valid. A key the
        // server has since invalidated (logged out from another device,
        // revoked, expired) therefore looked identical to a healthy login:
        // the app went straight to the main UI and then silently failed
        // every request, showing an empty gallery and "Could not load
        // account" with nothing explaining why or offering a way out. One
        // cheap authenticated call here turns that into an honest
        // "sign in again".
        final alive = await _sessionIsAlive();
        debugPrint('TVAUTH: _init sessionAlive=$alive');
        if (alive == false) {
          await TelegramService.instance.clearSession();
          state = const AuthState(
            step: AuthStep.initial,
            error: 'Your Telegram session expired. Please sign in again.',
          );
          return;
        }

        state = state.copyWith(step: AuthStep.authenticated, isLoading: false);
        return;
      } catch (e) {
        debugPrint('TVAUTH: _init attempt $attempt error: $e');
        if (attempt < 2) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        // Could not connect, but keep the session for a future launch.
        state = state.copyWith(step: AuthStep.initial, isLoading: false);
      }
    }
  }

  /// Server errors that mean the saved auth key is genuinely dead —
  /// reconnecting with the same key can never recover from these, only a
  /// fresh login can. Deliberately narrow: anything NOT listed here is
  /// treated as inconclusive and leaves the session alone, because wiping a
  /// good session over a transient error would force a full re-login (phone
  /// + OTP + 2FA) for nothing.
  static const _deadSessionErrors = {
    'AUTH_KEY_UNREGISTERED',
    'AUTH_KEY_INVALID',
    'AUTH_KEY_PERM_EMPTY',
    'SESSION_REVOKED',
    'SESSION_EXPIRED',
    'USER_DEACTIVATED',
  };

  /// Whether the restored session is actually usable, via one cheap
  /// authenticated request. `true` = the server accepted it, `false` = the
  /// server rejected the key itself, `null` = couldn't tell (network
  /// problem, rate limit, …), which must NOT be treated as a dead session.
  Future<bool?> _sessionIsAlive() async {
    try {
      final result = await TelegramService.instance
          .call((c) => c.users.getFullUser(id: const t.InputUserSelf()))
          .timeout(const Duration(seconds: 20));
      final message = result.error?.errorMessage;
      if (message == null) return true;
      if (_deadSessionErrors.any(message.startsWith)) return false;
      return null;
    } catch (e) {
      debugPrint('TVAUTH: _sessionIsAlive inconclusive: $e');
      return null;
    }
  }

  /// How long to wait for one auth request before giving up on it. Generous
  /// on purpose: sendCode in particular routinely takes well over 20s on a
  /// cold connection, and cutting it short is what used to trigger the
  /// replay described in [_withReconnect].
  static const _authTimeout = Duration(seconds: 45);

  /// Runs an MTProto [action] with one transparent reconnect-and-retry on a
  /// transport failure. Protocol responses (PHONE_CODE_INVALID,
  /// SESSION_PASSWORD_NEEDED, …) arrive as `result.error` inside the returned
  /// value — they are NOT thrown, so they pass straight through without
  /// triggering a retry.
  ///
  /// [replayable] is the important knob. A [SocketDeadException] fails fast
  /// *before* the request reaches the server, so replaying it is always safe.
  /// A timeout or a mid-flight socket error is NOT that: the server may well
  /// have received and acted on the request, and we simply didn't hear back.
  /// Replaying `auth.sendCode` in that situation actively broke login — the
  /// code had already been delivered, the replay went out over a brand-new
  /// auth key created by the reconnect, and the phoneCodeHash it returned
  /// belonged to a different session than the one the user was about to sign
  /// in on. Anything that consumes or issues a one-time code passes
  /// `replayable: false` and surfaces the timeout instead.
  Future<T> _withReconnect<T>(
    Future<T> Function() action, {
    bool replayable = true,
  }) async {
    Future<T> retry(String why, Object e) async {
      debugPrint('TVAUTH: _withReconnect $why, reconnecting: $e');
      await TelegramService.instance.reconnect();
      return action().timeout(_authTimeout);
    }

    try {
      return await action().timeout(_authTimeout);
    } on SocketDeadException catch (e) {
      // Fail-fast: never reached the server, safe to replay either way.
      return retry('socket dead', e);
    } on TimeoutException catch (e) {
      if (!replayable) rethrow;
      return retry('timeout', e);
    } on SocketException catch (e) {
      if (!replayable) rethrow;
      return retry('socket exception', e);
    }
  }

  /// Call when something has confirmed the saved session is genuinely dead
  /// (not a transient transport blip) — e.g. AUTH_KEY_UNREGISTERED persisting
  /// across many reconnect attempts on different requests, which reusing the
  /// same key can never recover from; only a fresh login can. Clears the
  /// saved session and drops back to the phone-number screen so the user
  /// sees they need to log in again, instead of the app silently retrying a
  /// dead key forever in the background.
  Future<void> invalidateSession() async {
    await TelegramService.instance.clearSession();
    state = const AuthState(step: AuthStep.initial);
  }

  String _friendlyError(Object e) {
    if (e is TimeoutException ||
        e is SocketDeadException ||
        e is SocketException) {
      return 'Connection problem. Please try again.';
    }
    return e.toString();
  }

  /// Turns a raw MTProto error string into something a person can act on.
  /// These used to be shown verbatim, so a rate-limited login read
  /// "FLOOD_WAIT_10021" — which looks like a crash, tells you nothing about
  /// what to do, and hides the one fact that matters: retrying right now
  /// makes it worse, not better.
  @visibleForTesting
  static String friendlyRpcError(String message) {
    final flood = RegExp(r'^FLOOD_WAIT_(\d+)$').firstMatch(message);
    if (flood != null) {
      final wait = _humanDuration(int.parse(flood.group(1)!));
      return 'Too many sign-in attempts — Telegram has paused this app for '
          '$wait. Trying again before then only extends the wait.';
    }
    return switch (message) {
      'PHONE_NUMBER_INVALID' =>
        "That number isn't valid. Include the country code, like "
            '+1 234 567 8900.',
      'PHONE_NUMBER_BANNED' => 'Telegram has banned this phone number.',
      'PHONE_CODE_INVALID' => "That code isn't right. Check it and try again.",
      'PHONE_CODE_EXPIRED' => 'That code expired. Request a new one.',
      'PHONE_CODE_EMPTY' => 'Enter the code Telegram sent you.',
      'PASSWORD_HASH_INVALID' => 'Wrong password.',
      'SESSION_PASSWORD_NEEDED' =>
        'This account has two-step verification enabled.',
      _ => message,
    };
  }

  static String _humanDuration(int seconds) {
    if (seconds < 60) return '$seconds seconds';
    final minutes = (seconds / 60).round();
    if (minutes < 60) return '$minutes minute${minutes == 1 ? '' : 's'}';
    final hours = seconds ~/ 3600;
    final remainder = ((seconds % 3600) / 60).round();
    final hoursPart = '$hours hour${hours == 1 ? '' : 's'}';
    if (remainder == 0) return hoursPart;
    return '$hoursPart ${remainder}m';
  }

  /// Telegram wants a bare `+<digits>` number. People type spaces, dashes and
  /// parentheses out of habit, and the server answers PHONE_NUMBER_INVALID
  /// for those rather than ignoring them, so strip everything that isn't a
  /// digit or the leading plus before sending.
  @visibleForTesting
  static String normalizePhone(String input) {
    final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
    return input.trimLeft().startsWith('+') ? '+$digits' : digits;
  }

  Future<void> sendCode(String rawPhoneNumber) async {
    final phoneNumber = normalizePhone(rawPhoneNumber);
    state = state.copyWith(isLoading: true, error: null);
    final started = DateTime.now();
    void trace(String what) => debugPrint(
      'TVAUTH: sendCode $what (+${DateTime.now().difference(started).inMilliseconds}ms)',
    );
    try {
      // Reuse a live connection instead of handshaking again. connect()
      // always negotiates a NEW authorization key, so calling it on every
      // Send Code tap both cost a full DH round trip before the request even
      // started and orphaned the key any earlier code had been issued on.
      if (!TelegramService.instance.isUsable) {
        trace('connecting');
        await TelegramService.instance.connect().timeout(
          const Duration(seconds: 30),
        );
      }
      trace('connected');

      // replayable: false — sendCode issues a real one-time code. Replaying
      // it after a timeout double-sends the code AND (because the retry runs
      // over the reconnect's brand-new auth key) hands back a phoneCodeHash
      // bound to a different session than the one signIn will use.
      Future<t.Result<t.AuthSentCodeBase>> send() => _withReconnect(
        () => TelegramService.instance.client.auth.sendCode(
          apiId: ApiCredentialsService.instance.apiId!,
          apiHash: ApiCredentialsService.instance.apiHash!,
          phoneNumber: phoneNumber,
          settings: const t.CodeSettings(
            allowFlashcall: false,
            currentNumber: true,
            allowAppHash: false,
            allowMissedCall: false,
            allowFirebase: false,
            unknownNumber: false,
          ),
        ),
        replayable: false,
      );

      var result = await send();
      trace('sendCode returned error=${result.error?.errorMessage}');

      // Handle DC migration (PHONE_MIGRATE_X)
      if (result.error != null) {
        final errorMsg = result.error!.errorMessage;
        if (errorMsg.startsWith('PHONE_MIGRATE_')) {
          final dcId = int.parse(errorMsg.split('_').last);
          trace('migrating to DC $dcId');
          await TelegramService.instance
              .reconnectToDc(dcId)
              .timeout(const Duration(seconds: 30));
          result = await send();
          trace('post-migrate error=${result.error?.errorMessage}');
        }
      }

      if (result.error != null) {
        state = state.copyWith(
          isLoading: false,
          error: friendlyRpcError(result.error!.errorMessage),
        );
        return;
      }

      final sentCode = result.result as t.AuthSentCode;
      state = state.copyWith(
        step: AuthStep.waitingCode,
        phoneNumber: phoneNumber,
        phoneCodeHash: sentCode.phoneCodeHash,
        isLoading: false,
      );
      trace('SUCCESS');
    } catch (e) {
      trace('FAILED: $e');
      // A transport failure here leaves a connection we can't trust — it may
      // be half-open, or wedged behind a request the server never answered.
      // Drop it so the next Send Code tap builds a clean one rather than
      // reusing this via isUsable (which only notices a *detectably* dead
      // socket).
      await TelegramService.instance.dropConnection();
      state = state.copyWith(isLoading: false, error: _friendlyError(e));
    }
  }

  Future<void> signIn(String code) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      // replayable: false — signIn consumes the one-time code, and the
      // phoneCodeHash is bound to the current session, so a reconnect would
      // invalidate it anyway.
      final result = await _withReconnect(
        () => TelegramService.instance.client.auth.signIn(
          phoneNumber: state.phoneNumber!,
          phoneCodeHash: state.phoneCodeHash!,
          phoneCode: code,
        ),
        replayable: false,
      );

      if (result.error != null) {
        final errorMsg = result.error!.errorMessage;
        if (errorMsg == 'SESSION_PASSWORD_NEEDED') {
          final passResult = await _withReconnect(
            () => TelegramService.instance.client.account.getPassword(),
          );
          final accountPassword = passResult.result as t.AccountPassword;
          state = state.copyWith(
            step: AuthStep.waitingPassword,
            accountPassword: accountPassword,
            isLoading: false,
          );
        } else {
          state = state.copyWith(
            isLoading: false,
            error: friendlyRpcError(errorMsg),
          );
        }
        return;
      }

      await TelegramService.instance.saveSession();
      state = state.copyWith(step: AuthStep.authenticated, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _friendlyError(e));
    }
  }

  Future<void> checkPassword(String password) async {
    debugPrint('TVAUTH: checkPassword START (len=${password.length})');
    state = state.copyWith(isLoading: true, error: null);
    try {
      // SRP params are single-use and time-limited — always fetch fresh.
      debugPrint('TVAUTH: checkPassword getPassword...');
      final passResult = await _withReconnect(
        () => TelegramService.instance.client.account.getPassword(),
      );
      debugPrint(
        'TVAUTH: checkPassword getPassword done, error=${passResult.error?.errorMessage}',
      );
      final accountPassword = passResult.result as t.AccountPassword;
      debugPrint('TVAUTH: checkPassword computing SRP...');
      final srp = await tg.check2FA(accountPassword, password);
      debugPrint(
        'TVAUTH: checkPassword SRP done, calling checkPassword RPC...',
      );
      // replayable: false — the SRP proof is computed against the params we
      // just fetched on THIS session; replaying it over a new auth key can
      // only fail (and burns a 2FA attempt).
      final result = await _withReconnect(
        () => TelegramService.instance.client.auth.checkPassword(password: srp),
        replayable: false,
      );
      debugPrint(
        'TVAUTH: checkPassword RPC done, error=${result.error?.errorMessage}',
      );

      if (result.error != null) {
        state = state.copyWith(
          isLoading: false,
          error: friendlyRpcError(result.error!.errorMessage),
        );
        return;
      }

      await TelegramService.instance.saveSession();
      debugPrint('TVAUTH: checkPassword SUCCESS, authenticated');
      state = state.copyWith(step: AuthStep.authenticated, isLoading: false);
    } catch (e, st) {
      debugPrint('TVAUTH: checkPassword EXCEPTION: $e\n$st');
      state = state.copyWith(isLoading: false, error: _friendlyError(e));
    }
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (_) => AuthNotifier(),
);
