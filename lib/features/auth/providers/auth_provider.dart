import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;
import '../../../core/config.dart';
import '../../../core/telegram/client.dart';

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
    try {
      final restored = await TelegramService.instance.restoreSession();
      state = state.copyWith(
        step: restored ? AuthStep.authenticated : AuthStep.initial,
        isLoading: false,
      );
    } catch (_) {
      await TelegramService.instance.clearSession();
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> sendCode(String phoneNumber) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final client = await TelegramService.instance.connect();
      var result = await client.auth.sendCode(
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
      );

      // Handle DC migration (PHONE_MIGRATE_X)
      if (result.error != null) {
        final errorMsg = result.error!.errorMessage;
        if (errorMsg.startsWith('PHONE_MIGRATE_')) {
          final dcId = int.parse(errorMsg.split('_').last);
          await TelegramService.instance.reconnectToDc(dcId);
          final newClient = TelegramService.instance.client;
          result = await newClient.auth.sendCode(
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
          );
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
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> signIn(String code) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final client = TelegramService.instance.client;
      final result = await client.auth.signIn(
        phoneNumber: state.phoneNumber!,
        phoneCodeHash: state.phoneCodeHash!,
        phoneCode: code,
      );

      if (result.error != null) {
        // SESSION_PASSWORD_NEEDED means 2FA is enabled
        final errorMsg = result.error!.errorMessage;
        if (errorMsg == 'SESSION_PASSWORD_NEEDED') {
          final passResult = await client.account.getPassword();
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
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> checkPassword(String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final client = TelegramService.instance.client;
      // SRP params (srp_id / srp_B) are single-use and time-limited, so fetch
      // them fresh for each attempt. Reusing the ones from signIn — which may
      // have expired while the user typed — yields SRP_ID_INVALID.
      final passResult = await client.account.getPassword();
      final accountPassword = passResult.result as t.AccountPassword;
      final srp = await tg.check2FA(accountPassword, password);
      final result = await client.auth.checkPassword(password: srp);

      if (result.error != null) {
        state = state.copyWith(isLoading: false, error: result.error!.errorMessage);
        return;
      }

      await TelegramService.instance.saveSession();
      state = state.copyWith(step: AuthStep.authenticated, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (_) => AuthNotifier(),
);
