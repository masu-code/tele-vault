// T1.3: every golden of test/goldens/tg_0_0_20_goldens.json (generated once
// from the ORIGINAL tg 0.0.20 code) reproduced by the NEW transport code, with
// a counting backend installed to prove the work goes through
// `TgCrypto.backend`. Also: unaligned views, the non-in-place AesCtr branch
// and random splits of the golden receive streams.
// T2.2: every test runs under both backends (pure Dart and native tv_crypto).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:t/t.dart' as t;
import 'package:test/test.dart';
import 'package:tg/src/crypto/backend.dart';
import 'package:tg/src/crypto/dart_backend.dart';
import 'package:tg/src/crypto/native_backend.dart';
import 'package:tg/tg.dart';

import '../tool/gen_goldens.dart';
import '../tool/reference/tg_0_0_20_reference.dart';

class CountingBackend implements TgCryptoBackend {
  CountingBackend(this._inner);

  final TgCryptoBackend _inner;
  int ige = 0;
  int ctr = 0;
  int sha = 0;

  @override
  String get name => 'counting-${_inner.name}';

  @override
  void aesIge({
    required bool encrypt,
    required Uint8List key32,
    required Uint8List iv32,
    required Uint8List input,
    required int inOffset,
    required int length,
    required Uint8List output,
    required int outOffset,
  }) {
    ige++;
    _inner.aesIge(
        encrypt: encrypt,
        key32: key32,
        iv32: iv32,
        input: input,
        inOffset: inOffset,
        length: length,
        output: output,
        outOffset: outOffset);
  }

  @override
  TgCtrStream createCtr(Uint8List key32, Uint8List iv16) {
    ctr++;
    return _inner.createCtr(key32, iv16);
  }

  @override
  void sha256(
      Uint8List data, int offset, int length, Uint8List out32, int outOffset) {
    sha++;
    _inner.sha256(data, offset, length, out32, outOffset);
  }
}

List<Map<String, dynamic>> _list(Object? v) =>
    (v as List).cast<Map<String, dynamic>>();

String _canonJson(t.TlObject m) => jsonEncode(canon(m));

AuthorizationKey _auth(Map a) => AuthorizationKey(
    a['id'] as int, unhex(a['key'] as String), a['salt'] as int);

/// [b] copied into a larger buffer at [offset] and returned as a view.
Uint8List _viewAt(Uint8List b, int offset) {
  final big = Uint8List(b.length + offset + 3);
  big.setRange(offset, offset + b.length, b);
  return Uint8List.sublistView(big, offset, offset + b.length);
}

/// Random chunking (1-byte chunks, sizes around frame boundaries, large).
List<Uint8List> _randomSplit(Uint8List wire, Random r) {
  final out = <Uint8List>[];
  var pos = 0;
  while (pos < wire.length) {
    final kind = r.nextInt(4);
    final size = switch (kind) {
      0 => 1,
      1 => 1 + r.nextInt(7),
      2 => 1 + r.nextInt(300),
      _ => 1 + r.nextInt(70000),
    };
    final end = min(pos + size, wire.length);
    out.add(Uint8List.sublistView(wire, pos, end));
    pos = end;
  }
  return out;
}

void main() {
  final g = jsonDecode(utf8.decode(
          File('test/goldens/tg_0_0_20_goldens.json').readAsBytesSync()))
      as Map<String, dynamic>;

  for (final (backendName, makeInner) in _backends) {
    group('backend $backendName', () {
      late CountingBackend counting;
      setUp(() {
        counting = CountingBackend(makeInner());
        expect(counting.name, 'counting-$backendName');
        TgCrypto.backend = counting;
      });
      tearDown(TgCrypto.resetForTesting);

      test('AES-IGE goldens (aligned and unaligned views)', () {
        final cases = _list(g['ige']);
        expect(cases.length, 40);
        for (var i = 0; i < cases.length; i++) {
          final c = cases[i];
          final input = unhex(c['input']);
          for (final off in [0, 1, 4, 13]) {
            final out = TgInternals.aesIge(
                off == 0 ? input : _viewAt(input, off),
                unhex(c['key']),
                unhex(c['iv']),
                encrypt: c['encrypt'] as bool);
            expect(hex(out), c['output'], reason: 'ige case $i offset $off');
          }
        }
        for (final c in _list(g['igeBig'])) {
          final out = TgInternals.aesIge(detBytes(c['inputSeed'], c['len']),
              unhex(c['key']), unhex(c['iv']),
              encrypt: c['encrypt'] as bool);
          expect(sha256Hex(out), c['outputSha256'], reason: 'len ${c['len']}');
        }
        expect(counting.ige, 40 * 4 + _list(g['igeBig']).length);
      });

      test('message crypt goldens x in {0, 8}', () {
        final cases = _list(g['msgcrypt']);
        expect(cases.length, 17);
        for (var i = 0; i < cases.length; i++) {
          final c = cases[i];
          final input = c.containsKey('input')
              ? unhex(c['input'])
              : detBytes(c['inputSeed'], c['len']);
          final before = Uint8List.fromList(input);
          final out = TgInternals.encryptDecryptMessage(input,
              encrypt: c['encrypt'] as bool,
              x: c['x'] as int,
              authKey: unhex(c['authKey']),
              msgKey: unhex(c['msgKey']),
              msgKeyOffset: c['msgKeyOffset'] as int);
          if (c.containsKey('output')) {
            expect(hex(out), c['output'], reason: 'msgcrypt case $i');
          } else {
            expect(sha256Hex(out), c['outputSha256'], reason: 'msgcrypt $i');
          }
          expect(input, before, reason: 'input must not be modified');
        }
        expect(counting.sha, 2 * 17);
        expect(counting.ige, 17);
      });

      test('encodeWithAuth / encodeNoAuth / frameToBytes goldens', () {
        final cases = _list(g['encodeWithAuth']);
        expect(cases.length, 9);
        for (var i = 0; i < cases.length; i++) {
          final c = cases[i];
          final out = TgInternals.encodeWithAuth(buildMessage(c['spec']),
              msgId: c['msgId'] as int,
              seqno: c['seqno'] as int,
              sessionId: c['sessionId'] as int,
              auth: _auth(c['auth'] as Map),
              padding: unhex(c['padding']));
          expect(out.length, c['outputLen'], reason: 'encodeWithAuth $i len');
          expect(sha256Hex(out), c['outputSha256'],
              reason: 'encodeWithAuth $i');
          if (c.containsKey('output')) expect(hex(out), c['output']);
        }
        // clear sha256 + 2 key-derivation sha256 + 1 IGE per frame.
        expect(counting.sha, 3 * 9);
        expect(counting.ige, 9);

        for (final c in _list(g['encodeNoAuth'])) {
          final out = TgInternals.encodeNoAuth(buildMessage(c['spec']),
              msgId: c['msgId']);
          expect(out.length, c['outputLen']);
          expect(sha256Hex(out), c['outputSha256']);
          if (c.containsKey('output')) expect(hex(out), c['output']);
        }
      });

      test('CTR goldens (in place and the original copy semantics)', () {
        final cases = _list(g['ctr']);
        expect(cases.length, 27);
        for (final c in cases) {
          final total = c['total'] as int;
          final chunks = List<int>.from(c['chunks'] as List);
          final input = detBytes(c['inputSeed'], total);
          final ctr = AesCtr(unhex(c['key']), unhex(c['iv']));
          final out = Uint8List(total);
          var pos = 0;
          var ci = 0;
          while (pos < total) {
            final size = (pos + chunks[ci % chunks.length] > total)
                ? total - pos
                : chunks[ci % chunks.length];
            // Alternate: Uint8List view at an odd offset (in place) and a plain
            // List<int> (copy path).
            if (ci.isEven) {
              final chunk =
                  _viewAt(Uint8List.sublistView(input, pos, pos + size), 3);
              ctr.encryptDecrypt(chunk, chunk.length);
              out.setRange(pos, pos + size, chunk);
            } else {
              final chunk = List<int>.from(input.sublist(pos, pos + size));
              ctr.encryptDecrypt(chunk, chunk.length);
              out.setRange(pos, pos + size, chunk);
            }
            ci++;
            pos += size;
          }
          final why = 'iv ${c['ivKind']} chunks $chunks';
          expect(sha256Hex(out), c['outputSha256'], reason: why);
        }
        expect(counting.ctr, 27);
      });

      test('AesCtr with length < input.length keeps the original semantics',
          () {
        final key = detBytes(11, 32);
        final iv = detBytes(12, 16);
        final r = Random(5);
        final ours = AesCtr(key, iv);
        final ref = RefAesCtr(key, iv);
        for (var i = 0; i < 30; i++) {
          final n = 1 + r.nextInt(100);
          final len = r.nextInt(n + 1);
          final a = detBytes(100 + i, n);
          final b = Uint8List.fromList(a);
          ours.encryptDecrypt(a, len);
          ref.encryptDecrypt(b, len);
          expect(a, b, reason: 'call $i n=$n len=$len');
        }
      });

      test('Obfuscation preamble and send/recv goldens', () {
        for (final c in _list(g['obfuscation'])) {
          final o = Obfuscation.preamble(
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
            o.send.encryptDecrypt(a, 64);
            expect(hex(a), sendOut[k], reason: 'send $k');
            final b = Uint8List.fromList(input);
            o.recv.encryptDecrypt(b, 64);
            expect(hex(b), recvOut[k], reason: 'recv $k');
          }
        }
        expect(counting.ctr, greaterThan(0));
      });

      test('parseFrame goldens (plain, obfuscated, unaligned)', () {
        final f = g['frames'] as Map<String, dynamic>;
        final authKey = unhex((f['authKey'] as Map)['key']);
        final authId = (f['authKey'] as Map)['id'] as int;
        for (final m in _list(f['messages'])) {
          for (final off in [0, 5]) {
            final body = unhex(m['bodyHex']);
            final r = TgInternals.parseFrame(
                off == 0 ? body : _viewAt(body, off), null, authKey);
            expect(r.authKeyId, authId);
            expect(r.messageId, m['msgId']);
            expect(r.seqno, m['seqno']);
            expect(_canonJson(r.message), jsonEncode(m['expectedJson']));
          }
        }
        final obfSpec = f['obf'] as Map<String, dynamic>;
        final po = f['parseObfuscated'] as Map<String, dynamic>;
        final m = _list(f['messages'])[po['index'] as int];
        final o = Obfuscation.preamble(unhex(obfSpec['random58']),
            obfSpec['padded'] as bool, obfSpec['dcId'] as int);
        final r = TgInternals.parseFrame(unhex(po['dataHex']), o, authKey);
        expect(r.messageId, m['msgId']);
        expect(r.seqno, m['seqno']);
        expect(_canonJson(r.message), jsonEncode(m['expectedJson']));
        expect(counting.ige, greaterThan(0));
      });

      test('encrypted receive stream: golden chunkings + 30 random splits',
          () async {
        final f = g['frames'] as Map<String, dynamic>;
        final obfSpec = f['obf'] as Map<String, dynamic>;
        final wire = unhex(f['wire']);
        final expected = _list(f['messages'])
            .map((m) => jsonEncode(m['expectedJson']))
            .toList();
        final expectedAcks = List<int>.from(f['expectedAcks'] as List);
        final r = Random(1311);
        final splits = [
          for (final ch in _list(f['chunkings'])) applyChunking(wire, ch),
          for (var i = 0; i < 30; i++) _randomSplit(wire, r),
        ];
        for (var s = 0; s < splits.length; s++) {
          final acks = <int>{};
          final got = await collectReceived(
            (raw) => TgInternals.encryptedReceiver(
              raw,
              Obfuscation.preamble(unhex(obfSpec['random58']),
                  obfSpec['padded'] as bool, obfSpec['dcId'] as int),
              _auth(f['authKey'] as Map),
              acks,
            ),
            splits[s],
          );
          expect(got.map(_canonJson).toList(), expected, reason: 'split $s');
          expect(acks.toList()..sort(), expectedAcks, reason: 'split $s');
        }
      });

      test('frameToBytes + unencrypted receive: golden + 30 random splits',
          () async {
        final u = g['unencrypted'] as Map<String, dynamic>;
        final obfSpec = u['obf'] as Map<String, dynamic>;
        Obfuscation freshObf() => Obfuscation.preamble(
            unhex(obfSpec['random58']),
            obfSpec['padded'] as bool,
            obfSpec['dcId'] as int);
        final frames = _list(u['frames']);
        for (final fr in frames) {
          final m = buildMessage(fr['spec']);
          expect(hex(TgInternals.frameToBytes(m, fr['msgId'] as int, null)),
              fr['frameToBytesPlain']);
          expect(
              hex(TgInternals.frameToBytes(m, fr['msgId'] as int, freshObf())),
              fr['frameToBytesObfFresh']);
        }
        final expected =
            frames.map((f) => jsonEncode(f['expectedJson'])).toList();
        final r = Random(1312);
        final plainWire = unhex(u['wirePlain']);
        final obfWire = unhex(u['wireObfuscated']);
        final chunkings = _list(u['chunkings']);
        for (var s = 0; s < chunkings.length + 30; s++) {
          final plainSplit = s < chunkings.length
              ? applyChunking(plainWire, chunkings[s])
              : _randomSplit(plainWire, r);
          final obfSplit = s < chunkings.length
              ? applyChunking(obfWire, chunkings[s])
              : _randomSplit(obfWire, r);
          final plain = await collectReceived(
              (raw) => TgInternals.unencryptedReceiver(raw, null, <int>{}),
              plainSplit);
          expect(plain.map(_canonJson).toList(), expected, reason: 'plain $s');
          final obf = await collectReceived(
              (raw) =>
                  TgInternals.unencryptedReceiver(raw, freshObf(), <int>{}),
              obfSplit);
          expect(obf.map(_canonJson).toList(), expected,
              reason: 'obfuscated $s');
        }
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
