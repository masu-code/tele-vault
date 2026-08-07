import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;
import '../../../core/config.dart';
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

  const AuthState({
    this.step = AuthStep.initial,
    this.phoneNumber,
    this.phoneCodeHash,
    this.accountPassword,
    this.isLoading = false,
    this.error,
  });

  bool get isAuthenticated => step == AuthStep.authenticated;

  AuthState copyWith({
    AuthStep? step,
    String? phoneNumber,
    String? phoneCodeHash,
    t.AccountPassword? accountPassword,
    bool? isLoading,
    String? error,
  }) =>
      AuthState(
        step: step ?? this.step,
        phoneNumber: phoneNumber ?? this.phoneNumber,
        phoneCodeHash: phoneCodeHash ?? this.phoneCodeHash,
        accountPassword: accountPassword ?? this.accountPassword,
        isLoading: isLoading ?? this.isLoading,
        error: error,
      );
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState()) {
    _init();
  }

  Future<void> _init() async {
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
        state = state.copyWith(
          step: restored ? AuthStep.authenticated : AuthStep.initial,
          isLoading: false,
        );
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

  /// Runs an MTProto [action] with one transparent reconnect-and-retry on a
  /// transport failure (socket killed by the OS / timeout). Protocol responses
  /// (PHONE_CODE_INVALID, SESSION_PASSWORD_NEEDED, …) arrive as `result.error`
  /// inside the returned value — they are NOT thrown, so they pass straight
  /// through without triggering a retry. Only real transport exceptions
  /// (TimeoutException, SocketDeadException, SocketException) reconnect.
  ///
  /// On a dead socket the very first send now fails fast with
  /// [SocketDeadException] (before the request reaches the server), so the
  /// retry re-sends to a fresh connection without double-consuming a code.
  Future<T> _withReconnect<T>(Future<T> Function() action) async {
    try {
      return await action().timeout(const Duration(seconds: 20));
    } on TimeoutException catch (e) {
      debugPrint('TVAUTH: _withReconnect timeout, reconnecting: $e');
      await TelegramService.instance.reconnect();
      return await action().timeout(const Duration(seconds: 20));
    } on SocketDeadException catch (e) {
      debugPrint('TVAUTH: _withReconnect socket dead, reconnecting: $e');
      await TelegramService.instance.reconnect();
      return await action().timeout(const Duration(seconds: 20));
    } on SocketException catch (e) {
      debugPrint('TVAUTH: _withReconnect socket exception, reconnecting: $e');
      await TelegramService.instance.reconnect();
      return await action().timeout(const Duration(seconds: 20));
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
    if (e is TimeoutException || e is SocketDeadException || e is SocketException) {
      return 'Connection problem. Please try again.';
    }
    return e.toString();
  }

  Future<void> sendCode(String phoneNumber) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await TelegramService.instance.connect()
          .timeout(const Duration(seconds: 30));

      var result = await _withReconnect(() =>
          TelegramService.instance.client.auth.sendCode(
            apiId: Config.apiId,
            apiHash: Config.apiHash,
            phoneNumber: phoneNumber,
            settings: const t.CodeSettings(
              allowFlashcall: false,
              currentNumber: true,
              allowAppHash: false,
              allowMissedCall: false,
              allowFirebase: false,
              unknownNumber: false,
            ),
          ));

      // Handle DC migration (PHONE_MIGRATE_X)
      if (result.error != null) {
        final errorMsg = result.error!.errorMessage;
        if (errorMsg.startsWith('PHONE_MIGRATE_')) {
          final dcId = int.parse(errorMsg.split('_').last);
          await TelegramService.instance.reconnectToDc(dcId)
              .timeout(const Duration(seconds: 30));
          result = await _withReconnect(() =>
              TelegramService.instance.client.auth.sendCode(
                apiId: Config.apiId,
                apiHash: Config.apiHash,
                phoneNumber: phoneNumber,
                settings: const t.CodeSettings(
                  allowFlashcall: false,
                  currentNumber: true,
                  allowAppHash: false,
                  allowMissedCall: false,
                  allowFirebase: false,
                  unknownNumber: false,
                ),
              ));
        }
      }

      if (result.error != null) {
        state = state.copyWith(isLoading: false, error: result.error!.errorMessage);
        return;
      }

      final sentCode = result.result as t.AuthSentCode;
      state = state.copyWith(
        step: AuthStep.waitingCode,
        phoneNumber: phoneNumber,
        phoneCodeHash: sentCode.phoneCodeHash,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: _friendlyError(e));
    }
  }

  Future<void> signIn(String code) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _withReconnect(() =>
          TelegramService.instance.client.auth.signIn(
            phoneNumber: state.phoneNumber!,
            phoneCodeHash: state.phoneCodeHash!,
            phoneCode: code,
          ));

      if (result.error != null) {
        final errorMsg = result.error!.errorMessage;
        if (errorMsg == 'SESSION_PASSWORD_NEEDED') {
          final passResult = await _withReconnect(
              () => TelegramService.instance.client.account.getPassword());
          final accountPassword = passResult.result as t.AccountPassword;
          state = state.copyWith(
            step: AuthStep.waitingPassword,
            accountPassword: accountPassword,
            isLoading: false,
          );
        } else {
          state = state.copyWith(isLoading: false, error: errorMsg);
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
          () => TelegramService.instance.client.account.getPassword());
      debugPrint('TVAUTH: checkPassword getPassword done, error=${passResult.error?.errorMessage}');
      final accountPassword = passResult.result as t.AccountPassword;
      debugPrint('TVAUTH: checkPassword computing SRP...');
      final srp = await tg.check2FA(accountPassword, password);
      debugPrint('TVAUTH: checkPassword SRP done, calling checkPassword RPC...');
      final result = await _withReconnect(() =>
          TelegramService.instance.client.auth.checkPassword(password: srp));
      debugPrint('TVAUTH: checkPassword RPC done, error=${result.error?.errorMessage}');

      if (result.error != null) {
        state = state.copyWith(isLoading: false, error: result.error!.errorMessage);
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
