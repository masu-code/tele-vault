// T1.4: incoming msg_key / length / padding verification. A frame that fails
// is dropped inside the transformer with exactly one `TVDIAG: tg dropped frame`
// line, nothing is emitted for it, nothing escapes the stream listener, and
// the next valid frame still decodes.
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:t/t.dart' as t;
import 'package:test/test.dart';
import 'package:tg/tg.dart';

import '../tool/gen_goldens.dart' show collectReceived, detBytes, serializeObject;

Uint8List _le(int v, int n) {
  final b = Uint8List(n);
  final bd = ByteData.sublistView(b);
  if (n == 8) {
    bd.setUint64(0, v, Endian.little);
  } else {
    bd.setUint32(0, v, Endian.little);
  }
  return b;
}

Uint8List _sha(List<int> a) => Uint8List.fromList(c.sha256.convert(a).bytes);

final _authKey = detBytes(7100, 256);
const _authId = 0x0A0B0C0D0E0F1011;
final _random58 = detBytes(7101, 58);

/// Server plaintext: salt | session | msgId | seqno | msg_len | body | padding.
Uint8List _plain(Uint8List body,
    {required int msgId, required int pad, int? msgLen, int session = 0x2222}) {
  return (BytesBuilder()
        ..add(_le(0x1111, 8))
        ..add(_le(session, 8))
        ..add(_le(msgId, 8))
        ..add(_le(1, 4)) // odd seqno: the transformer queues an ack
        ..add(_le(msgLen ?? body.length, 4))
        ..add(body)
        ..add(detBytes(msgId, pad)))
      .toBytes();
}

/// Transport frame (length prefix + body, no obfuscation) with a valid
/// msg_key for [plain] under [key], labelled with [authId].
Uint8List _frame(Uint8List plain, {Uint8List? key, int authId = _authId}) {
  final k = key ?? _authKey;
  final msgKey = _sha([...k.sublist(96, 128), ...plain]).sublist(8, 24);
  final cipher = TgInternals.encryptDecryptMessage(plain,
      encrypt: true, x: 8, authKey: k, msgKey: msgKey, msgKeyOffset: 0);
  final body = (BytesBuilder()
        ..add(_le(authId, 8))
        ..add(msgKey)
        ..add(cipher))
      .toBytes();
  return (BytesBuilder()
        ..add(_le(body.length, 4))
        ..add(body))
      .toBytes();
}

Uint8List _pong(int pingId) => serializeObject(t.Pong(msgId: 1, pingId: pingId));

/// A valid frame carrying Pong(pingId); pad 12 is the smallest valid padding.
Uint8List _validFrame(int pingId, {int pad = 12}) =>
    _frame(_plain(_pong(pingId), msgId: 0x7000 + pingId * 4, pad: pad));

class _Result {
  _Result(this.got, this.logs, this.errors, this.acks);
  final List<t.TlObject> got;
  final List<String> logs;
  final List<Object> errors;
  final Set<int> acks;
}

/// Feeds [frames] (in order, obfuscated as one stream) through the encrypted
/// receiver in 5 uneven chunks, capturing prints and uncaught errors.
Future<_Result> _run(List<Uint8List> frames, {int? sessionId}) async {
  final wire = (BytesBuilder()..add(frames.expand((f) => f).toList())).toBytes();
  Obfuscation.preamble(_random58, false, 2).recv.encryptDecrypt(wire, wire.length);
  final chunks = <Uint8List>[];
  for (var pos = 0, i = 0; pos < wire.length; i++) {
    final size = [1, 7, 61, 500, 100000][i % 5];
    final end = pos + size > wire.length ? wire.length : pos + size;
    chunks.add(Uint8List.sublistView(wire, pos, end));
    pos = end;
  }

  final logs = <String>[];
  final errors = <Object>[];
  final acks = <int>{};
  late List<t.TlObject> got;
  await runZonedGuarded(() async {
    got = await collectReceived(
      (raw) => TgInternals.encryptedReceiver(
        raw,
        Obfuscation.preamble(_random58, false, 2),
        AuthorizationKey(_authId, _authKey, 0),
        acks,
        sessionId: sessionId,
      ),
      chunks,
    );
  }, (e, s) => errors.add(e),
      zoneSpecification:
          ZoneSpecification(print: (self, parent, zone, line) => logs.add(line)));
  return _Result(got, logs, errors, acks);
}

List<int> _pingIds(List<t.TlObject> got) =>
    got.map((m) => (m as t.Pong).pingId).toList();

void main() {
  test('verification is on by default', () {
    expect(kVerifyIncomingMsgKey, isTrue);
  });

  test('valid frames pass (min and max padding, uneven chunking)', () async {
    final r = await _run([
      _validFrame(1, pad: 12),
      _validFrame(2, pad: 28),
      _validFrame(3, pad: 1020),
    ]);
    expect(r.errors, isEmpty);
    expect(r.logs, isEmpty);
    expect(_pingIds(r.got), [1, 2, 3]);
    expect(r.acks, {0x7000 + 4, 0x7000 + 8, 0x7000 + 12});
  });

  Uint8List flipBit(Uint8List frame, int byteIndex) {
    final f = Uint8List.fromList(frame);
    f[byteIndex] ^= 0x01;
    return f;
  }

  // Offsets inside a transport frame: [0,4) length, [4,12) auth_key_id,
  // [12,28) msg_key, [28,..) ciphertext.
  final cases = <String, ({Uint8List bad, String reason})>{
    'flipped ciphertext bit (first block)': (
      bad: flipBit(_validFrame(10), 28),
      reason: 'msg_key mismatch',
    ),
    'flipped ciphertext bit (last block)': (
      bad: () {
        final f = _validFrame(10);
        return flipBit(f, f.length - 1);
      }(),
      reason: 'msg_key mismatch',
    ),
    'flipped msg_key bit': (
      bad: flipBit(_validFrame(10), 12 + 9),
      reason: 'msg_key mismatch',
    ),
    'msg_len beyond the plaintext (valid msg_key)': (
      bad: _frame(_plain(_pong(10), msgId: 0x9000, pad: 12, msgLen: 0x7FFFFFF0)),
      reason: 'bad msg_len',
    ),
    'msg_len with the high bit set (valid msg_key)': (
      bad: _frame(_plain(_pong(10), msgId: 0x9000, pad: 12, msgLen: 0xFFFFFFF0)),
      reason: 'bad msg_len',
    ),
    'padding shorter than 12 (valid msg_key)': (
      bad: _frame(_plain(detBytes(1, 8), msgId: 0x9000, pad: 8)),
      reason: 'bad padding length',
    ),
    'padding longer than 1024 (valid msg_key)': (
      bad: _frame(_plain(_pong(10), msgId: 0x9000, pad: 1036)),
      reason: 'bad padding length',
    ),
    'body shorter than one header': (
      bad: (BytesBuilder()
            ..add(_le(8 + 16 + 16, 4))
            ..add(_le(_authId, 8))
            ..add(detBytes(5, 32)))
          .toBytes(),
      reason: 'bad frame length',
    ),
    'body that is not whole AES blocks': (
      bad: (BytesBuilder()
            ..add(_le(8 + 16 + 36, 4))
            ..add(_le(_authId, 8))
            ..add(detBytes(6, 52)))
          .toBytes(),
      reason: 'bad frame length',
    ),
    // F2: a plaintext frame has no msg_key, so an on-path attacker who saw
    // the obfuscation preamble could inject one (e.g. BadMsgNotification 16).
    'plaintext frame (auth_key_id 0)': (
      bad: TgInternals.frameToBytes(
          const t.BadMsgNotification(
              badMsgId: 0x7000 + 4, badMsgSeqno: 1, errorCode: 16),
          0x9000,
          null),
      reason: 'unencrypted',
    ),
    'plaintext Pong (auth_key_id 0)': (
      bad: TgInternals.frameToBytes(t.Pong(msgId: 1, pingId: 10), 0x9004, null),
      reason: 'unencrypted',
    ),
    'foreign auth_key_id (valid msg_key under another key)': (
      bad: _frame(_plain(_pong(10), msgId: 0x9000, pad: 12),
          key: detBytes(7200, 256), authId: 0x1122334455667788),
      reason: 'foreign auth_key_id',
    ),
    'foreign auth_key_id (our key, wrong id)': (
      bad: _frame(_plain(_pong(10), msgId: 0x9000, pad: 12),
          authId: _authId ^ 1),
      reason: 'foreign auth_key_id',
    ),
  };

  for (final entry in cases.entries) {
    test('dropped, stream keeps working: ${entry.key}', () async {
      final r = await _run([
        _validFrame(1),
        entry.value.bad,
        _validFrame(2),
      ]);
      expect(r.errors, isEmpty, reason: 'nothing may escape the listener');
      expect(_pingIds(r.got), [1, 2]);
      expect(r.logs, ['TVDIAG: tg dropped frame: ${entry.value.reason}']);
      expect(r.acks, {0x7000 + 4, 0x7000 + 8},
          reason: 'the dropped frame must not be acked');
    });
  }

  test('session_id: own session passes, a foreign one is dropped', () async {
    final r = await _run([
      _validFrame(1),
      _frame(_plain(_pong(10), msgId: 0x9000, pad: 12, session: 0x3333)),
      _validFrame(2),
    ], sessionId: 0x2222);
    expect(r.errors, isEmpty);
    expect(_pingIds(r.got), [1, 2]);
    expect(r.logs, ['TVDIAG: tg dropped frame: foreign session_id']);
    expect(r.acks, {0x7000 + 4, 0x7000 + 8});
  });

  test('only a bad frame: nothing emitted, one log line', () async {
    final r = await _run([flipBit(_validFrame(1), 40)]);
    expect(r.errors, isEmpty);
    expect(r.got, isEmpty);
    expect(r.logs.length, 1);
    expect(r.logs.single, startsWith('TVDIAG: tg dropped frame'));
  });

  test('several bad frames in a row, then a valid one', () async {
    final r = await _run([
      flipBit(_validFrame(1), 30),
      flipBit(_validFrame(2), 14),
      _frame(_plain(_pong(3), msgId: 0x9000, pad: 12, msgLen: 0x7FFFFFF0)),
      _validFrame(4),
    ]);
    expect(r.errors, isEmpty);
    expect(_pingIds(r.got), [4]);
    expect(r.logs.length, 3);
    expect(r.logs.every((l) => l.startsWith('TVDIAG: tg dropped frame')),
        isTrue);
  });
}
