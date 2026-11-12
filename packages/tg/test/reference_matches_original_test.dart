// Proves that BOTH the ORIGINAL tg 0.0.20 code (reached through TgInternals /
// Obfuscation / AesCtr) and the frozen reference copy
// (tool/reference/tg_0_0_20_reference.dart) reproduce every golden output of
// test/goldens/tg_0_0_20_goldens.json, which was generated once from the
// unmodified code. Later tasks reuse the goldens to prove optimized code is
// byte-identical.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:t/t.dart' as t;
import 'package:test/test.dart';
import 'package:tg/tg.dart';

import '../tool/gen_goldens.dart';
import '../tool/reference/tg_0_0_20_reference.dart';

typedef ParsedFrame = ({
  t.TlObject message,
  int messageId,
  int authKeyId,
  int? seqno
});

/// Opaque obfuscation wrapper so the same test body drives both implementations.
class Obf {
  Obf(this.raw, this.preamble, this.send, this.recv);
  final Object raw;
  final Uint8List preamble;
  final void Function(List<int>, int) send;
  final void Function(List<int>, int) recv;
}

class Impl {
  Impl({
    required this.name,
    required this.ige,
    required this.msgCrypt,
    required this.encWithAuth,
    required this.encNoAuth,
    required this.newCtr,
    required this.newObf,
    required this.parseFrame,
    required this.encRecv,
    required this.unencRecv,
    required this.frameToBytes,
  });

  final String name;
  final Uint8List Function(Uint8List input, Uint8List key, Uint8List iv, bool enc)
      ige;
  final Uint8List Function(Uint8List input, bool enc, int x, List<int> authKey,
      Uint8List msgKey, int offset) msgCrypt;
  final Uint8List Function(t.TlObject m, int msgId, int seqno, int sessionId,
      Map<String, dynamic> auth, Uint8List padding) encWithAuth;
  final Uint8List Function(t.TlObject m, int msgId) encNoAuth;
  final void Function(List<int>, int) Function(Uint8List key, Uint8List iv)
      newCtr;
  final Obf Function(Uint8List random58, bool padded, int dc, Uint8List? secret)
      newObf;
  final ParsedFrame Function(Uint8List data, Obf? o, List<int> authKey)
      parseFrame;
  final Stream<t.TlObject> Function(
          Stream<List<int>> raw, Obf o, Map<String, dynamic> auth, Set<int> acks)
      encRecv;
  final Stream<t.TlObject> Function(
      Stream<List<int>> raw, Obf? o, Set<int> acks) unencRecv;
  final Uint8List Function(t.TlObject m, int msgId, Obf? o) frameToBytes;
}

AuthorizationKey _auth(Map<String, dynamic> a) =>
    AuthorizationKey(a['id'] as int, unhex(a['key'] as String), a['salt'] as int);

final original = Impl(
  name: 'original (TgInternals)',
  ige: (input, key, iv, enc) =>
      TgInternals.aesIge(input, key, iv, encrypt: enc),
  msgCrypt: (input, enc, x, authKey, msgKey, off) =>
      TgInternals.encryptDecryptMessage(input,
          encrypt: enc, x: x, authKey: authKey, msgKey: msgKey, msgKeyOffset: off),
  encWithAuth: (m, msgId, seqno, sessionId, auth, padding) =>
      TgInternals.encodeWithAuth(m,
          msgId: msgId,
          seqno: seqno,
          sessionId: sessionId,
          auth: _auth(auth),
          padding: padding),
  encNoAuth: (m, msgId) => TgInternals.encodeNoAuth(m, msgId: msgId),
  newCtr: (key, iv) => AesCtr(key, iv).encryptDecrypt,
  newObf: (random58, padded, dc, secret) {
    final o = Obfuscation.preamble(random58, padded, dc, secret);
    return Obf(o, o.preamble, o.send.encryptDecrypt, o.recv.encryptDecrypt);
  },
  parseFrame: (data, o, authKey) =>
      TgInternals.parseFrame(data, o?.raw as Obfuscation?, authKey),
  encRecv: (raw, o, auth, acks) => TgInternals.encryptedReceiver(
      raw, o.raw as Obfuscation, _auth(auth), acks),
  unencRecv: (raw, o, acks) =>
      TgInternals.unencryptedReceiver(raw, o?.raw as Obfuscation?, acks),
  frameToBytes: (m, msgId, o) =>
      TgInternals.frameToBytes(m, msgId, o?.raw as Obfuscation?),
);

final reference = Impl(
  name: 'reference copy',
  ige: (input, key, iv, enc) =>
      refAesIgeEncryptDecrypt(input, RefAesKeyIV(key, iv), enc),
  msgCrypt: refEncryptDecryptMessage,
  encWithAuth: (m, msgId, seqno, sessionId, auth, padding) =>
      refEncodeWithAuthPadded(
        m,
        RefIdSeq(msgId, seqno),
        sessionId,
        RefAuthKey(
            auth['id'] as int, unhex(auth['key'] as String), auth['salt'] as int),
        padding,
      ),
  encNoAuth: (m, msgId) => refEncodeNoAuth(m, RefIdSeq(msgId, 0)),
  newCtr: (key, iv) => RefAesCtr(key, iv).encryptDecrypt,
  newObf: (random58, padded, dc, secret) {
    final o = RefObfuscation.preamble(random58, padded, dc, secret);
    return Obf(o, o.preamble, o.send.encryptDecrypt, o.recv.encryptDecrypt);
  },
  parseFrame: (data, o, authKey) {
    final f = RefFrame.parse(data, o?.raw as RefObfuscation?, authKey);
    return (
      message: f.message,
      messageId: f.messageId,
      authKeyId: f.authKeyId,
      seqno: f.seqno,
    );
  },
  encRecv: (raw, o, auth, acks) => RefEncryptedTransformer(
          raw, o.raw as RefObfuscation, unhex(auth['key'] as String), acks)
      .stream,
  unencRecv: (raw, o, acks) =>
      RefUnEncryptedTransformer(raw, acks, o?.raw as RefObfuscation?).stream,
  frameToBytes: (m, msgId, o) =>
      RefFrame(m, msgId, 0, null).toUint8List(o?.raw as RefObfuscation?),
);

List<Map<String, dynamic>> _list(Object? v) =>
    (v as List).cast<Map<String, dynamic>>();

String _canonJson(t.TlObject m) => jsonEncode(canon(m));

void main() {
  final fixtureFile = File('test/goldens/tg_0_0_20_goldens.json');
  final fixtureBytes = fixtureFile.readAsBytesSync();
  final g = jsonDecode(utf8.decode(fixtureBytes)) as Map<String, dynamic>;

  group('fixture', () {
    test('is under 2 MB', () {
      expect(fixtureBytes.length, lessThan(2 * 1024 * 1024));
    });

    test('sha256 matches VENDORED.md (never regenerate)', () {
      final md = File('VENDORED.md').readAsStringSync();
      final m = RegExp(r'^sha256: ([0-9a-f]{64})\s*$', multiLine: true)
          .firstMatch(md);
      expect(m, isNotNull, reason: 'VENDORED.md has no sha256 line');
      expect(sha256Hex(fixtureBytes), m!.group(1));
    });
  });

  for (final impl in [original, reference]) {
    group(impl.name, () {
      test('AES-IGE (40 explicit cases)', () {
        final cases = _list(g['ige']);
        expect(cases.length, 40);
        for (var i = 0; i < cases.length; i++) {
          final c = cases[i];
          final out = impl.ige(unhex(c['input']), unhex(c['key']),
              unhex(c['iv']), c['encrypt'] as bool);
          expect(hex(out), c['output'], reason: 'ige case $i');
        }
      });

      test('AES-IGE 64 KiB and 1 MiB (sha256)', () {
        for (final c in _list(g['igeBig'])) {
          final input = detBytes(c['inputSeed'], c['len']);
          final out = impl.ige(input, unhex(c['key']), unhex(c['iv']),
              c['encrypt'] as bool);
          expect(sha256Hex(out), c['outputSha256'], reason: 'len ${c['len']}');
        }
      });

      test('message crypt x in {0, 8}', () {
        final cases = _list(g['msgcrypt']);
        expect(cases.length, 17);
        for (var i = 0; i < cases.length; i++) {
          final c = cases[i];
          final input = c.containsKey('input')
              ? unhex(c['input'])
              : detBytes(c['inputSeed'], c['len']);
          final out = impl.msgCrypt(
            input,
            c['encrypt'] as bool,
            c['x'] as int,
            unhex(c['authKey']),
            unhex(c['msgKey']),
            c['msgKeyOffset'] as int,
          );
          if (c.containsKey('output')) {
            expect(hex(out), c['output'], reason: 'msgcrypt case $i');
          } else {
            expect(sha256Hex(out), c['outputSha256'], reason: 'msgcrypt $i');
          }
        }
      });

      test('encodeWithAuth with explicit padding', () {
        final cases = _list(g['encodeWithAuth']);
        expect(cases.length, 9);
        for (var i = 0; i < cases.length; i++) {
          final c = cases[i];
          final out = impl.encWithAuth(
            buildMessage(c['spec']),
            c['msgId'] as int,
            c['seqno'] as int,
            c['sessionId'] as int,
            c['auth'] as Map<String, dynamic>,
            unhex(c['padding']),
          );
          expect(out.length, c['outputLen'], reason: 'encodeWithAuth $i len');
          expect(sha256Hex(out), c['outputSha256'], reason: 'encodeWithAuth $i');
          if (c.containsKey('output')) expect(hex(out), c['output']);
        }
      });

      test('encodeNoAuth', () {
        for (final c in _list(g['encodeNoAuth'])) {
          final out = impl.encNoAuth(buildMessage(c['spec']), c['msgId'] as int);
          expect(out.length, c['outputLen']);
          expect(sha256Hex(out), c['outputSha256']);
          if (c.containsKey('output')) expect(hex(out), c['output']);
        }
      });

      test('CTR streams with chunk patterns', () {
        final cases = _list(g['ctr']);
        expect(cases.length, 27);
        for (final c in cases) {
          final total = c['total'] as int;
          final chunks = List<int>.from(c['chunks'] as List);
          final input = detBytes(c['inputSeed'], total);
          final process = impl.newCtr(unhex(c['key']), unhex(c['iv']));
          final out = Uint8List(total);
          var pos = 0;
          var ci = 0;
          while (pos < total) {
            final size = (pos + chunks[ci % chunks.length] > total)
                ? total - pos
                : chunks[ci % chunks.length];
            ci++;
            final chunk = Uint8List.fromList(input.sublist(pos, pos + size));
            process(chunk, chunk.length);
            out.setRange(pos, pos + size, chunk);
            pos += size;
          }
          final why = 'iv ${c['ivKind']} chunks $chunks';
          expect(sha256Hex(out), c['outputSha256'], reason: why);
          if (c.containsKey('output')) expect(hex(out), c['output'], reason: why);
        }
      });

      test('Obfuscation preamble and send/recv streams', () {
        for (final c in _list(g['obfuscation'])) {
          final o = impl.newObf(
            unhex(c['random58']),
            c['padded'] as bool,
            c['dcId'] as int,
            c.containsKey('secret') ? unhex(c['secret']) : null,
          );
          expect(hex(o.preamble), c['preamble']);
          final input = detBytes(c['inputSeed'], 64);
          final sendOut = List<String>.from(c['sendOut'] as List);
          final recvOut = List<String>.from(c['recvOut'] as List);
          for (var k = 0; k < sendOut.length; k++) {
            final a = Uint8List.fromList(input);
            o.send(a, 64);
            expect(hex(a), sendOut[k], reason: 'send $k');
            final b = Uint8List.fromList(input);
            o.recv(b, 64);
            expect(hex(b), recvOut[k], reason: 'recv $k');
          }
        }
      });

      test('parseFrame of server frames (no obfuscation)', () {
        final f = g['frames'] as Map<String, dynamic>;
        final authKey = unhex((f['authKey'] as Map)['key']);
        final authId = (f['authKey'] as Map)['id'] as int;
        for (final m in _list(f['messages'])) {
          final r = impl.parseFrame(unhex(m['bodyHex']), null, authKey);
          expect(r.authKeyId, authId);
          expect(r.messageId, m['msgId']);
          expect(r.seqno, m['seqno']);
          expect(_canonJson(r.message), jsonEncode(m['expectedJson']));
        }
      });

      test('parseFrame with obfuscation', () {
        final f = g['frames'] as Map<String, dynamic>;
        final obfSpec = f['obf'] as Map<String, dynamic>;
        final po = f['parseObfuscated'] as Map<String, dynamic>;
        final m = _list(f['messages'])[po['index'] as int];
        final o = impl.newObf(unhex(obfSpec['random58']),
            obfSpec['padded'] as bool, obfSpec['dcId'] as int, null);
        final r = impl.parseFrame(
            unhex(po['dataHex']), o, unhex((f['authKey'] as Map)['key']));
        expect(r.messageId, m['msgId']);
        expect(r.seqno, m['seqno']);
        expect(_canonJson(r.message), jsonEncode(m['expectedJson']));
      });

      test('encrypted receive stream (all chunkings, acks)', () async {
        final f = g['frames'] as Map<String, dynamic>;
        final obfSpec = f['obf'] as Map<String, dynamic>;
        final wire = unhex(f['wire']);
        final expected = _list(f['messages']);
        final expectedAcks = List<int>.from(f['expectedAcks'] as List);
        for (final chunking in _list(f['chunkings'])) {
          final acks = <int>{};
          final got = await collectReceived(
            (raw) => impl.encRecv(
              raw,
              impl.newObf(unhex(obfSpec['random58']), obfSpec['padded'] as bool,
                  obfSpec['dcId'] as int, null),
              f['authKey'] as Map<String, dynamic>,
              acks,
            ),
            applyChunking(wire, chunking),
          );
          expect(got.length, expected.length, reason: '$chunking');
          for (var i = 0; i < got.length; i++) {
            expect(_canonJson(got[i]), jsonEncode(expected[i]['expectedJson']),
                reason: 'frame $i with $chunking');
          }
          expect(acks.toList()..sort(), expectedAcks);
        }
      });

      test('frameToBytes and unencrypted receive streams', () async {
        final u = g['unencrypted'] as Map<String, dynamic>;
        final obfSpec = u['obf'] as Map<String, dynamic>;
        Obf freshObf() => impl.newObf(unhex(obfSpec['random58']),
            obfSpec['padded'] as bool, obfSpec['dcId'] as int, null);
        final frames = _list(u['frames']);
        for (final fr in frames) {
          final m = buildMessage(fr['spec']);
          expect(hex(impl.frameToBytes(m, fr['msgId'] as int, null)),
              fr['frameToBytesPlain']);
          expect(hex(impl.frameToBytes(m, fr['msgId'] as int, freshObf())),
              fr['frameToBytesObfFresh']);
        }
        final expected = frames.map((f) => jsonEncode(f['expectedJson'])).toList();
        for (final chunking in _list(u['chunkings'])) {
          final plain = await collectReceived(
            (raw) => impl.unencRecv(raw, null, <int>{}),
            applyChunking(unhex(u['wirePlain']), chunking),
          );
          expect(plain.map(_canonJson).toList(), expected,
              reason: 'plain $chunking');
          final obf = await collectReceived(
            (raw) => impl.unencRecv(raw, freshObf(), <int>{}),
            applyChunking(unhex(u['wireObfuscated']), chunking),
          );
          expect(obf.map(_canonJson).toList(), expected,
              reason: 'obfuscated $chunking');
        }
      });
    });
  }
}
