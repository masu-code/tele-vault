import 'dart:math';
import 'package:t/t.dart' as t;

final _random = Random.secure();

/// A random 64-bit id, used for Telegram's `randomId` (message dedup) and
/// `fileId` (upload session id).
int randomInt64() {
  final hi = _random.nextInt(1 << 32);
  final lo = _random.nextInt(1 << 32);
  return (hi << 32) | lo;
}

/// After sending a message/media with [randomId], Telegram echoes the assigned
/// message id back via an [t.UpdateMessageID]. Returns it, or null if absent.
int? extractSentMessageId(t.UpdatesBase? updates, int randomId) {
  final list = switch (updates) {
    t.Updates(:final updates) => updates,
    t.UpdatesCombined(:final updates) => updates,
    _ => const <t.UpdateBase>[],
  };
  for (final u in list) {
    if (u is t.UpdateMessageID && u.randomId == randomId) return u.id;
  }
  return null;
}
