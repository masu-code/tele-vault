import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/auth/providers/auth_provider.dart';

/// Telegram answers PHONE_NUMBER_INVALID for a number that carries the
/// separators people naturally type ("+58 412-555-1234"), which is exactly
/// what the login hint text invites. Everything but the digits and a leading
/// plus has to go before the number reaches auth.sendCode.
void main() {
  group('AuthNotifier.normalizePhone', () {
    test('strips spaces, dashes and parentheses but keeps the plus', () {
      expect(AuthNotifier.normalizePhone('+58 412-555 1234'), '+584125551234');
      expect(AuthNotifier.normalizePhone('+1 (234) 567-8900'), '+12345678900');
    });

    test('keeps a number without a plus unprefixed', () {
      expect(AuthNotifier.normalizePhone('584125551234'), '584125551234');
      expect(AuthNotifier.normalizePhone('412 555 1234'), '4125551234');
    });

    test('tolerates surrounding whitespace', () {
      expect(AuthNotifier.normalizePhone('  +584125551234  '), '+584125551234');
    });

    test('leaves an already-clean number untouched', () {
      expect(AuthNotifier.normalizePhone('+584125551234'), '+584125551234');
    });
  });
}
