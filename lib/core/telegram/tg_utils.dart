import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:t/t.dart' as t;
import 'client.dart';

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

/// Pulls the message list out of the various MessagesMessages* containers.
List<t.MessageBase> extractMessages(t.MessagesMessagesBase? base) => switch (base) {
      t.MessagesMessages(:final messages) => messages,
      t.MessagesMessagesSlice(:final messages) => messages,
      t.MessagesChannelMessages(:final messages) => messages,
      _ => const [],
    };

final _floodWaitPattern = RegExp(r'FLOOD_WAIT_(\d+)');

/// If [errorMessage] is a Telegram flood-wait error ("FLOOD_WAIT_5"), the
/// number of seconds to wait before retrying. Null for any other error.
int? floodWaitSeconds(String errorMessage) {
  final match = _floodWaitPattern.firstMatch(errorMessage);
  return match == null ? null : int.parse(match.group(1)!);
}

/// Runs an RPC [action] and, if the result is a Telegram flood-wait error,
/// waits the requested duration and retries the call — up to [maxRetries]
/// times — returning whatever the last attempt produced either way (success
/// or a different/persistent error), unchanged from what the caller would
/// normally do with the raw result.
///
/// Editing the same message repeatedly in a short span (e.g. saving the
/// vault index once per changed file while uploading or auto-backing-up
/// several files in a row) is exactly the kind of call Telegram
/// flood-limits — later files in a batch are the most likely to hit it, and
/// without a retry the file would finish uploading to Telegram but never
/// make it into the index, becoming invisible everywhere in the app despite
/// already consuming storage.
Future<t.Result<T>> withFloodWaitRetry<T extends t.TlObject>(
  Future<t.Result<T>> Function() action, {
  int maxRetries = 3,
}) async {
  for (var attempt = 0; ; attempt++) {
    final result = await action();
    final seconds =
        result.error == null ? null : floodWaitSeconds(result.error!.errorMessage);
    if (seconds == null || attempt >= maxRetries) return result;
    debugPrint('TVQUEUE: FLOOD_WAIT ${seconds}s (attempt $attempt)');
    await Future.delayed(Duration(seconds: seconds + 1));
  }
}

/// Backoff window currently in effect after [withAuthKeyRetry] exhausted its
/// retries for some previous call. Shared across all callers (not per-file):
/// once the connection is confirmed broken, every file hitting it back-to-back
/// within milliseconds just reproduces the same failure, so later callers wait
/// out the remaining window before even trying instead of piling on more
/// doomed reconnect attempts.
DateTime? _authKeyBackoffUntil;

/// How many *consecutive* calls have exhausted retries since the last
/// success — grows the backoff window each time, resets to zero on any call
/// that doesn't hit AUTH_KEY_UNREGISTERED at all (including on its first try).
int _consecutiveAuthKeyFailures = 0;

const _authKeyBackoffSteps = [5, 15, 30, 60];

/// Runs an RPC [action] and, if the result is Telegram's AUTH_KEY_UNREGISTERED
/// error, forces a fresh reconnect and retries — up to [maxRetries] times.
///
/// Observed in practice (including with plain sequential, non-concurrent
/// uploads) as a sporadic, non-fatal hiccup rather than a genuinely revoked
/// session: reconnecting and resending the same request goes through fine
/// the next time. Without this, a single spurious occurrence mid-upload
/// would otherwise be treated as a dead session for the rest of the run.
///
/// Also observed: sometimes it is NOT a one-off — reconnecting with the same
/// authorization key fails identically for every subsequent file, minutes on
/// end, because reusing that key can never succeed until whatever caused the
/// server to reject it clears up (seen recover on its own after the process
/// was killed and relaunched, i.e. after enough real wall-clock time passed —
/// not because the relaunch itself changed anything reconnect() doesn't
/// already do). Hammering every file in the queue with fresh reconnect
/// attempts one second apart during that window doesn't help it recover and
/// just wastes the whole remaining backlog as immediate failures. So once
/// retries are exhausted for one call, later calls back off for a growing
/// window (5s/15s/30s/60s) before even attempting, giving the server-side
/// condition time to clear instead of hammering it.
Future<t.Result<T>> withAuthKeyRetry<T extends t.TlObject>(
  Future<t.Result<T>> Function() action, {
  int maxRetries = 2,
}) async {
  final backoffUntil = _authKeyBackoffUntil;
  if (backoffUntil != null) {
    final wait = backoffUntil.difference(DateTime.now());
    if (wait > Duration.zero) {
      debugPrint('TVQUEUE: AUTH_KEY backoff, waiting ${wait.inSeconds}s before next attempt');
      await Future.delayed(wait);
    }
  }

  for (var attempt = 0; ; attempt++) {
    final result = await action();
    final isAuthKeyError = result.error?.errorMessage == 'AUTH_KEY_UNREGISTERED';
    if (!isAuthKeyError) {
      _consecutiveAuthKeyFailures = 0;
      _authKeyBackoffUntil = null;
      return result;
    }
    if (attempt >= maxRetries) {
      final step = _authKeyBackoffSteps[
          _consecutiveAuthKeyFailures.clamp(0, _authKeyBackoffSteps.length - 1)];
      _consecutiveAuthKeyFailures++;
      _authKeyBackoffUntil = DateTime.now().add(Duration(seconds: step));
      debugPrint('TVQUEUE: AUTH_KEY_UNREGISTERED persists after $maxRetries retries, '
          'backing off ${step}s (consecutive failure #$_consecutiveAuthKeyFailures)');
      return result;
    }
    debugPrint('TVQUEUE: AUTH_KEY_UNREGISTERED, reconnecting (attempt $attempt)');
    await TelegramService.instance.reconnect();
    await Future.delayed(const Duration(seconds: 1));
  }
}
