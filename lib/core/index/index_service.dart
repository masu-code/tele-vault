import 'package:t/t.dart' as t;
import '../../models/file_index.dart';
import '../telegram/client.dart';
import '../telegram/tg_utils.dart';

/// Reads and writes the vault index to the user's Telegram "Saved Messages".
///
/// The index lives in a single self-chat message, tagged with [_marker] so it
/// can be found again on any device. The first line is the marker; the rest is
/// the JSON payload.
///
/// LIMITATION: Telegram text messages cap at 4096 UTF-16 code units, which
/// bounds how many entries fit here (~20-40 files). Phase 3 will migrate the
/// index to an uploaded JSON document to remove this ceiling. The public API
/// of this service is kept storage-agnostic so that swap stays internal.
class IndexService {
  IndexService._();
  static final IndexService instance = IndexService._();

  static const String _marker = 'TELEVAULT_INDEX_V1';
  static const int _maxMessageLength = 4096;

  /// Telegram message id of the index message, once known. Cached so updates
  /// can edit in place instead of posting a new message.
  int? _messageId;

  int? get messageId => _messageId;

  t.Client get _client => TelegramService.instance.client;

  /// Loads the index from Saved Messages, scanning recent history for the
  /// tagged message. Returns an empty index if none exists yet.
  Future<FileIndex> load() async {
    final result = await _client.messages.getHistory(
      peer: const t.InputPeerSelf(),
      offsetId: 0,
      offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
      addOffset: 0,
      limit: 100,
      maxId: 0,
      minId: 0,
      hash: 0,
    );

    if (result.error != null) {
      throw IndexException('Failed to read history: ${result.error!.errorMessage}');
    }

    final messages = extractMessages(result.result);
    for (final msg in messages) {
      if (msg is t.Message && msg.message.startsWith(_marker)) {
        _messageId = msg.id;
        final payload = msg.message.substring(_marker.length).trimLeft();
        if (payload.isEmpty) return FileIndex.empty();
        try {
          return FileIndex.decode(payload);
        } catch (e) {
          throw IndexException('Index message is corrupt: $e');
        }
      }
    }

    // No index yet on this account.
    _messageId = null;
    return FileIndex.empty();
  }

  /// Persists [index] to Saved Messages. Edits the existing index message when
  /// one is known, otherwise creates it.
  Future<void> save(FileIndex index) async {
    final body = '$_marker\n${index.encode()}';

    if (body.length > _maxMessageLength) {
      throw IndexException(
        'Index exceeds the $_maxMessageLength-char message limit '
        '(${body.length}). Document-backed storage lands in Phase 3.',
      );
    }

    final id = _messageId;
    if (id != null) {
      final result = await _client.messages.editMessage(
        noWebpage: true,
        invertMedia: false,
        peer: const t.InputPeerSelf(),
        id: id,
        message: body,
      );
      if (result.error != null) {
        // The message may have been deleted on another device; fall back to
        // creating a fresh one.
        _messageId = null;
        await _create(body);
      }
      return;
    }

    await _create(body);
  }

  Future<void> _create(String body) async {
    final randomId = randomInt64();
    final result = await _client.messages.sendMessage(
      noWebpage: true,
      silent: true,
      background: false,
      clearDraft: false,
      noforwards: false,
      updateStickersetsOrder: false,
      invertMedia: false,
      allowPaidFloodskip: false,
      peer: const t.InputPeerSelf(),
      message: body,
      randomId: randomId,
    );

    if (result.error != null) {
      throw IndexException('Failed to write index: ${result.error!.errorMessage}');
    }

    _messageId = extractSentMessageId(result.result, randomId);
  }

}

class IndexException implements Exception {
  final String message;
  IndexException(this.message);
  @override
  String toString() => 'IndexException: $message';
}
