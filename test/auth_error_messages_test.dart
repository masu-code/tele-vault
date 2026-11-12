import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/auth/providers/auth_provider.dart';

// The device run that finally explained the broken login surfaced
// "FLOOD_WAIT_10021" verbatim on the login screen. That reads as a crash,
// says nothing about what to do, and hides the one thing that matters:
// retrying makes the wait longer. These pin the translation.
void main() {
  group('AuthNotifier.friendlyRpcError', () {
    test('explains FLOOD_WAIT in hours and warns against retrying', () {
      final message = AuthNotifier.friendlyRpcError('FLOOD_WAIT_10021');
      expect(message, contains('2 hours'));
      expect(message, contains('47m'));
      expect(message.toLowerCase(), contains('extends the wait'));
      expect(message, isNot(contains('FLOOD_WAIT')));
    });

    test('scales FLOOD_WAIT down to minutes and seconds', () {
      expect(AuthNotifier.friendlyRpcError('FLOOD_WAIT_30'), contains('30 seconds'));
      expect(AuthNotifier.friendlyRpcError('FLOOD_WAIT_120'), contains('2 minutes'));
      expect(AuthNotifier.friendlyRpcError('FLOOD_WAIT_3600'), contains('1 hour'));
    });

    test('rewrites the common phone/code rejections', () {
      expect(
        AuthNotifier.friendlyRpcError('PHONE_NUMBER_INVALID'),
        contains('country code'),
      );
      expect(
        AuthNotifier.friendlyRpcError('PHONE_CODE_EXPIRED'),
        contains('expired'),
      );
      expect(
        AuthNotifier.friendlyRpcError('PASSWORD_HASH_INVALID'),
        'Wrong password.',
      );
    });

    test('passes an unknown error through untouched', () {
      expect(
        AuthNotifier.friendlyRpcError('SOMETHING_NEW_42'),
        'SOMETHING_NEW_42',
      );
    });
  });
}
