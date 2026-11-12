// T1.3: client->server encode with the production random padding, decrypted
// with x = 0 and the msg_key checked; the recovered padding re-encoded by the
// frozen reference must give the same bytes. Server->client streams built
// here, split at random, must decode to the same objects as the reference.
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:t/t.dart' as t;
import 'package:test/test.dart';
import 'package:tg/src/crypto/backend.dart';
import 'package:tg/src/crypto/dart_backend.dart';
import 'package:tg/src/crypto/native_backend.dart';
import 'package:tg/tg.dart';

import '../tool/gen_goldens.dart';
import '../tool/reference/tg_0_0_20_reference.dart';

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

/// Server -> client encrypted frame body (after the 4-byte length): plaintext
/// with the server msg_key = sha256(authKey[96:128] || plaintext)[8:24],
/// IGE with x = 8.
Uint8List serverFrameBody(Uint8List body, Uint8List authKey, int authId,
    {required int msgId, required int seqno, required int padSeed}) {
  final b = BytesBuilder()
    ..add(_le(0x1111, 8))
    ..add(_le(0x2222, 8))
    ..add(_le(msgId, 8))
    ..add(_le(seqno, 4))
    ..add(_le(body.length, 4))
    ..add(body);
  var pad = 12 + (padSeed % 5) * 16;
  pad += (16 - ((32 + body.length + pad) % 16)) % 16;
  b.add(detBytes(padSeed, pad));
  final plain = b.toBytes();
  final msgKey = _sha([...authKey.sublist(96, 128), ...plain]).sublist(8, 24);
  final cipher = TgInternals.encryptDecryptMessage(plain,
      encrypt: true, x: 8, authKey: authKey, msgKey: msgKey, msgKeyOffset: 0);
  return (BytesBuilder()
        ..add(_le(authId, 8))
        ..add(msgKey)
        ..add(cipher))
      .toBytes();
}

/// Wire bytes of [m]. t's `MsgContainer.serialize` omits its constructor id
/// (the server sends it), so it is prepended here.
Uint8List tlBytes(t.TlObject m) {
  final b = serializeObject(m);
  if (m is! t.MsgContainer) return b;
  return Uint8List.fromList([..._le(0x73f1f8dc, 4), ...b]);
}

List<Uint8List> randomSplit(Uint8List wire, Random r) {
  final out = <Uint8List>[];
  var pos = 0;
  while (pos < wire.length) {
    final size = switch (r.nextInt(4)) {
      0 => 1,
      1 => 1 + r.nextInt(7),
      2 => 1 + r.nextInt(500),
      _ => 1 + r.nextInt(100000),
    };
    final end = min(pos + size, wire.length);
    out.add(Uint8List.sublistView(wire, pos, end));
    pos = end;
  }
  return out;
}

String canonJson(t.TlObject m) => jsonEncode(canon(m));

void main() {
  for (final (backendName, makeBackend) in _backends) {
    group('backend $backendName', () {
      setUp(() => TgCrypto.backend = makeBackend());
      tearDown(TgCrypto.resetForTesting);

      final authKey = detBytes(900, 256);
      const authId = 0x0123456789ABCDEF;
      const salt = 0x7766554433221100;
      final auth = AuthorizationKey(authId, authKey, salt);

      group('encode -> decrypt (x = 0) with msg_key check', () {
        final messages = <t.TlObject>[
          const t.HelpGetConfig(),
          t.MsgsAck(msgIds: [1, 2, 3, 0x7FFFFFFFFFFFFFF0]),
          for (final n in [0, 1, 253, 254, 255, 4096, 524288])
            t.UploadSaveFilePart(
                fileId: -42 - n, filePart: n, bytes: detBytes(1000 + n, n)),
        ];

        test('every message, random padding, matches the reference bytes', () {
          for (var i = 0; i < messages.length; i++) {
            final m = messages[i];
            final msgId = 0x6000000000000000 + i * 4;
            final seqno = 2 * i + 1;
            const sessionId = -0x1234567890;
            final frame = TgInternals.encodeWithAuthRandomPadding(m,
                msgId: msgId, seqno: seqno, sessionId: sessionId, auth: auth);
            final bd = ByteData.sublistView(frame);

            expect(bd.getUint32(0, Endian.little), frame.length - 4);
            expect(bd.getUint64(4, Endian.little), authId);
            final msgKey = Uint8List.fromList(frame.sublist(12, 28));
            final plain = TgInternals.encryptDecryptMessage(
                Uint8List.fromList(frame.sublist(28)),
                encrypt: false,
                x: 0,
                authKey: authKey,
                msgKey: msgKey,
                msgKeyOffset: 0);
            // Client msg_key: sha256(authKey[88:120] || plaintext)[8:24].
            expect(_sha([...authKey.sublist(88, 120), ...plain]).sublist(8, 24),
                msgKey,
                reason: 'msg_key of message $i');

            final pd = ByteData.sublistView(plain);
            expect(pd.getUint64(0, Endian.little), salt);
            expect(pd.getUint64(8, Endian.little), sessionId);
            expect(pd.getUint64(16, Endian.little), msgId);
            expect(pd.getUint32(24, Endian.little), seqno);
            final body = serializeObject(m);
            expect(pd.getUint32(28, Endian.little), body.length);
            expect(plain.sublist(32, 32 + body.length), body);

            final padLen = plain.length - 32 - body.length;
            expect(padLen, inInclusiveRange(32, 255), reason: 'padding $i');
            expect(plain.length % 16, 0);

            // Same padding through the frozen reference: identical frame.
            final ref = refEncodeWithAuthPadded(
              m,
              RefIdSeq(msgId, seqno),
              sessionId,
              RefAuthKey(authId, authKey, salt),
              Uint8List.fromList(plain.sublist(32 + body.length)),
            );
            expect(frame, ref, reason: 'reference bytes of message $i');
          }
        });

        test('padding is random (not the old (i+1)%256 pattern)', () {
          final seen = <String>{};
          for (var i = 0; i < 20; i++) {
            final frame = TgInternals.encodeWithAuthRandomPadding(
                const t.HelpGetConfig(),
                msgId: 0x6000000000000000,
                seqno: 1,
                sessionId: 7,
                auth: auth);
            final plain = TgInternals.encryptDecryptMessage(
                Uint8List.fromList(frame.sublist(28)),
                encrypt: false,
                x: 0,
                authKey: authKey,
                msgKey: Uint8List.fromList(frame.sublist(12, 28)),
                msgKeyOffset: 0);
            final pad = plain
                .sublist(32 + serializeObject(const t.HelpGetConfig()).length);
            // The old getBytes filled the padding buffer with (k + 1) % 256.
            final pattern =
                List<int>.generate(pad.length, (k) => (k + 1) % 256);
            expect(pad, isNot(pattern));
            seen.add(hex(pad));
          }
          expect(seen.length, 20, reason: 'every padding must differ');
        });
      });

      group('server -> client streams, random splits vs reference', () {
        // A mix that covers big frames, containers, gzip and odd/even seqnos.
        final nearest = t.NearestDc(country: 'XX', thisDc: 2, nearestDc: 4);
        final nearestBytes = serializeObject(nearest);
        final messages = <t.TlObject>[
          t.RpcResult(
              reqMsgId: 0x100,
              result: t.UploadFile(
                  type: const t.StorageFileJpeg(),
                  mtime: 1700000000,
                  bytes: detBytes(77, 300 * 1024))),
          t.Pong(msgId: 0x200, pingId: 99),
          t.MsgContainer(messages: [
            t.Msg(
                msgId: 0x301,
                seqno: 3,
                bytes: 0,
                body: t.Pong(msgId: 1, pingId: 2)),
            t.Msg(
                msgId: 0x305,
                seqno: 4,
                bytes: 0,
                body: const t.NewSessionCreated(
                    firstMsgId: 5, uniqueId: 6, serverSalt: 7)),
          ]),
          t.RpcResult(
              reqMsgId: 0x400,
              result: t.GzipPacked(
                  packedData: Uint8List.fromList(gzip.encode(nearestBytes)))),
          t.RpcResult(
              reqMsgId: 0x500,
              result: t.UploadFile(
                  type: const t.StorageFileJpeg(),
                  mtime: 1,
                  bytes: detBytes(78, 1000))),
        ];

        test('encrypted: 30 random splits decode like the reference', () async {
          final random58 = detBytes(901, 58);
          final wireB = BytesBuilder();
          for (var i = 0; i < messages.length; i++) {
            final body = serverFrameBody(tlBytes(messages[i]), authKey, authId,
                msgId: 0x7000000000000001 + i * 4, seqno: i, padSeed: 950 + i);
            wireB
              ..add(_le(body.length, 4))
              ..add(body);
          }
          final wire = wireB.toBytes();
          RefObfuscation.preamble(random58, false, 2)
              .recv
              .encryptDecrypt(wire, wire.length);

          final refAcks = <int>{};
          final expected = await collectReceived(
              (raw) => RefEncryptedTransformer(
                      raw,
                      RefObfuscation.preamble(random58, false, 2),
                      authKey,
                      refAcks)
                  .stream,
              [wire]);
          expect(expected.length, messages.length);

          final r = Random(902);
          for (var s = 0; s < 30; s++) {
            final acks = <int>{};
            final got = await collectReceived(
                (raw) => TgInternals.encryptedReceiver(
                    raw, Obfuscation.preamble(random58, false, 2), auth, acks),
                randomSplit(wire, r));
            expect(
                got.map(canonJson).toList(), expected.map(canonJson).toList(),
                reason: 'split $s');
            expect(acks, refAcks, reason: 'split $s');
          }
        });

        test('unencrypted: 30 random splits decode like the reference',
            () async {
          final random58 = detBytes(903, 58);
          final plain = BytesBuilder();
          final unenc = messages.where((m) => m is! t.MsgContainer).toList();
          for (var i = 0; i < unenc.length; i++) {
            plain.add(TgInternals.frameToBytes(
                unenc[i], 0x7100000000000000 + i, null));
          }
          final wire = plain.toBytes();
          final obfWire = Uint8List.fromList(wire);
          RefObfuscation.preamble(random58, true, 4)
              .recv
              .encryptDecrypt(obfWire, obfWire.length);

          final expected = await collectReceived(
              (raw) => RefUnEncryptedTransformer(
                      raw, <int>{}, RefObfuscation.preamble(random58, true, 4))
                  .stream,
              [obfWire]);
          expect(expected.length, unenc.length);

          final r = Random(904);
          for (var s = 0; s < 30; s++) {
            final got = await collectReceived(
                (raw) => TgInternals.unencryptedReceiver(
                    raw, Obfuscation.preamble(random58, true, 4), <int>{}),
                randomSplit(obfWire, r));
            expect(
                got.map(canonJson).toList(), expected.map(canonJson).toList(),
                reason: 'split $s');
          }
        });
      });
    });
  }
}

TgCryptoBackend _nativeOrFail() =>
    NativeCryptoBackend.tryCreate() ??
    fail('native tv_crypto library could not be loaded');

final _backends = <(String, TgCryptoBackend Function())>[
  ('dart', DartCryptoBackend.new),
  ('native', _nativeOrFail),
];
