// T2.2: backend selection (lazy, one TVDIAG line, never throws) and parity of
// NativeCryptoBackend (tv_crypto) with DartCryptoBackend on random vectors:
// views at offsets 0/1/4/24/32 (unaligned included), in-place IGE, CTR split
// at arbitrary byte boundaries, SHA-256 at offsets. Accelerated and forced
// portable native paths.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tg/src/crypto/backend.dart';
import 'package:tg/src/crypto/dart_backend.dart';
import 'package:tg/src/crypto/native_backend.dart';
import 'package:tv_crypto/tv_crypto.dart';

Uint8List _rnd(Random r, int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

/// [data] copied at [offset] of a larger buffer, returned as a view.
Uint8List _at(Uint8List data, int offset) {
  final big = Uint8List(offset + data.length + 7);
  big.setRange(offset, offset + data.length, data);
  return Uint8List.sublistView(big, offset, offset + data.length);
}

/// Wraps the Dart backend with one primitive broken (or throwing).
class _Broken implements TgCryptoBackend {
  _Broken(this.what);
  final String what;
  final _d = DartCryptoBackend();

  @override
  String get name => 'broken-$what';

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
    if (what == 'throw') throw StateError('boom');
    _d.aesIge(
        encrypt: encrypt,
        key32: key32,
        iv32: iv32,
        input: input,
        inOffset: inOffset,
        length: length,
        output: output,
        outOffset: outOffset);
    if (what == (encrypt ? 'igeEnc' : 'igeDec')) output[outOffset + 17] ^= 1;
  }

  @override
  TgCtrStream createCtr(Uint8List key32, Uint8List iv16) {
    final s = _d.createCtr(key32, iv16);
    return what == 'ctr' ? _BrokenCtr(s) : s;
  }

  @override
  void sha256(
      Uint8List data, int offset, int length, Uint8List out32, int outOffset) {
    _d.sha256(data, offset, length, out32, outOffset);
    if (what == 'sha') out32[outOffset + 31] ^= 0x80;
  }
}

/// Restarts the keystream on every call (not byte-granular continuation).
class _BrokenCtr implements TgCtrStream {
  _BrokenCtr(this._s);
  final TgCtrStream _s;
  var _calls = 0;
  @override
  void process(Uint8List data, int offset, int length) {
    _s.process(data, offset, length);
    if (_calls++ == 1 && length > 0) data[offset] ^= 1;
  }

  @override
  void dispose() => _s.dispose();
}

void main() {
  // Must be the first test of this isolate: it observes the lazy resolution.
  test('TgCrypto.backend resolves lazily once, logs one TVDIAG line', () {
    final lines = <String>[];
    late TgCryptoBackend first, again;
    runZoned(() {
      first = TgCrypto.backend;
      again = TgCrypto.backend; // cached, no second line
    }, zoneSpecification: ZoneSpecification(print: (_, __, ___, line) {
      lines.add(line);
    }));
    expect(identical(first, again), isTrue);
    expect(lines, hasLength(1));
    expect(lines.single,
        matches(RegExp(r'^TVDIAG: tg crypto backend=(native|dart)/\S+$')));
    expect(
        lines.single, startsWith('TVDIAG: tg crypto backend=${first.name}/'));
    // On the dev PC tv_crypto is built by its hook: native must be chosen.
    if (TgCrypto.nativeEnabled) expect(first.name, 'native');

    // An installed backend wins; reset restores the resolved one silently.
    final dart = DartCryptoBackend();
    runZoned(() {
      TgCrypto.backend = dart;
      expect(identical(TgCrypto.backend, dart), isTrue);
      TgCrypto.resetForTesting();
      expect(identical(TgCrypto.backend, first), isTrue);
    }, zoneSpecification: ZoneSpecification(print: (_, __, ___, line) {
      lines.add(line);
    }));
    expect(lines, hasLength(1));
  });

  group('selectCryptoBackend', () {
    test('disabled -> dart/off, native loader not called', () {
      final log = <String>[];
      var called = false;
      final b = selectCryptoBackend(
          enabled: false,
          loadNative: () {
            called = true;
            return NativeCryptoBackend.tryCreate();
          },
          log: log.add);
      expect(b, isA<DartCryptoBackend>());
      expect(called, isFalse);
      expect(log, ['TVDIAG: tg crypto backend=dart/off']);
    });

    test('library missing -> dart/none', () {
      final log = <String>[];
      final b = selectCryptoBackend(
          enabled: true, loadNative: () => null, log: log.add);
      expect(b, isA<DartCryptoBackend>());
      expect(log, ['TVDIAG: tg crypto backend=dart/none']);
    });

    test('loader throws -> dart, never throws', () {
      final log = <String>[];
      final b = selectCryptoBackend(
          enabled: true,
          loadNative: () => throw StateError('load failed'),
          log: log.add);
      expect(b, isA<DartCryptoBackend>());
      expect(log, hasLength(1));
      expect(log.single, startsWith('TVDIAG: tg crypto backend=dart/'));
    });

    test('log throwing does not escape', () {
      final b = selectCryptoBackend(
          enabled: true,
          loadNative: () => null,
          log: (_) => throw StateError('log'));
      expect(b, isA<DartCryptoBackend>());
    });

    test('native loads and passes the cross-check -> native/<info hex>', () {
      final log = <String>[];
      final b = selectCryptoBackend(
          enabled: true,
          loadNative: NativeCryptoBackend.tryCreate,
          log: log.add);
      expect(b, isA<NativeCryptoBackend>());
      final info = (b as NativeCryptoBackend).info;
      expect(log, [
        'TVDIAG: tg crypto backend=native/'
            '0x${info.toRadixString(16).padLeft(2, '0')}'
      ]);
    });
  });

  group('crossCheckBackend', () {
    test('accepts dart and native', () {
      expect(crossCheckBackend(DartCryptoBackend()), isTrue);
      expect(crossCheckBackend(NativeCryptoBackend.tryCreate()!), isTrue);
    });
    for (final what in ['igeEnc', 'igeDec', 'ctr', 'sha', 'throw']) {
      test('rejects a backend with broken $what', () {
        expect(crossCheckBackend(_Broken(what)), isFalse);
      });
    }
  });

  for (final portable in [false, true]) {
    group('native vs dart parity (forcePortable=$portable)', () {
      final tv = TvCrypto.tryLoad();
      final dart = DartCryptoBackend();
      late NativeCryptoBackend native;
      setUp(() {
        expect(tv, isNotNull, reason: 'tv_crypto must load on the dev PC');
        tv!.forcePortableForTesting(portable);
        native = NativeCryptoBackend(tv);
      });
      tearDown(() => tv?.forcePortableForTesting(false));

      test('info bits reflect the forced path', () {
        final info = native.info;
        if (portable) {
          expect(info & TvCryptoInfo.aesAccelActive, 0);
          expect(info & TvCryptoInfo.shaAccelActive, 0);
        }
        expect(info & TvCryptoInfo.portableFailed, 0);
      });

      test('AES-IGE enc/dec, views at 0/1/4/24/32, in place', () {
        final r = Random(portable ? 71 : 70);
        for (final len in [16, 32, 48, 160, 1024, 4096 + 16, 65536]) {
          for (final off in [0, 1, 4, 24, 32]) {
            for (final encrypt in [true, false]) {
              final key = _rnd(r, 32);
              final iv = _rnd(r, 32);
              final data = _rnd(r, len);
              final expected = Uint8List(len);
              dart.aesIge(
                  encrypt: encrypt,
                  key32: key,
                  iv32: iv,
                  input: data,
                  inOffset: 0,
                  length: len,
                  output: expected,
                  outOffset: 0);
              final why = 'len $len off $off enc $encrypt';

              // Out of place: input view at [off], output buffer at [off].
              final inView = _at(data, off);
              final outBuf = Uint8List(len + off + 3);
              native.aesIge(
                  encrypt: encrypt,
                  key32: key,
                  iv32: iv,
                  input: inView,
                  inOffset: 0,
                  length: len,
                  output: outBuf,
                  outOffset: off);
              expect(Uint8List.sublistView(outBuf, off, off + len), expected,
                  reason: '$why out of place');
              expect(inView, data, reason: '$why input untouched');

              // In place, same buffer and offset (as the frame decoder does).
              final buf = Uint8List(len + off + 5)
                ..setRange(off, off + len, data);
              native.aesIge(
                  encrypt: encrypt,
                  key32: key,
                  iv32: iv,
                  input: buf,
                  inOffset: off,
                  length: len,
                  output: buf,
                  outOffset: off);
              expect(Uint8List.sublistView(buf, off, off + len), expected,
                  reason: '$why in place');
              expect(buf.sublist(0, off), everyElement(0));
              expect(buf.sublist(off + len), everyElement(0));
            }
          }
        }
      });

      test('AES-CTR random byte-granular splits, unaligned views', () {
        final r = Random(portable ? 81 : 80);
        for (var round = 0; round < 12; round++) {
          final key = _rnd(r, 32);
          final iv = round == 0
              ? (Uint8List(16)..fillRange(0, 16, 0xff))
              : _rnd(r, 16);
          final total = 1 + r.nextInt(70000);
          final data = _rnd(r, total);
          final expected = Uint8List.fromList(data);
          final d = dart.createCtr(key, iv);
          d.process(expected, 0, total);
          d.dispose();

          final off = [0, 1, 4, 24, 32][round % 5];
          final view = _at(data, off);
          final n = native.createCtr(key, iv);
          var pos = 0;
          while (pos < total) {
            final size = min(
                total - pos,
                switch (r.nextInt(4)) {
                  0 => 1,
                  1 => 1 + r.nextInt(31),
                  2 => 1 + r.nextInt(600),
                  _ => 1 + r.nextInt(20000),
                });
            n.process(view, pos, size);
            pos += size;
          }
          n.dispose();
          expect(view, expected, reason: 'round $round total $total');
        }
      });

      test('SHA-256 lengths and offsets', () {
        final r = Random(portable ? 91 : 90);
        final lens = [0, 1, 3, 52, 55, 56, 63, 64, 65, 119, 1000, 70001];
        for (final len in lens) {
          for (final off in [0, 1, 4, 24, 32]) {
            final data = _at(_rnd(r, len), off);
            final a = Uint8List(32);
            dart.sha256(data, 0, len, a, 0);
            final b = Uint8List(40);
            native.sha256(
                data.buffer.asUint8List(), data.offsetInBytes, len, b, off % 9);
            expect(Uint8List.sublistView(b, off % 9, off % 9 + 32), a,
                reason: 'len $len off $off');
          }
        }
        // Input and output in one buffer (as _messageKeyIv does).
        final s = _rnd(r, 168);
        final expected = Uint8List(32);
        dart.sha256(s, 52, 52, expected, 0);
        native.sha256(s, 52, 52, s, 136);
        expect(Uint8List.sublistView(s, 136, 168), expected);
      });
    });
  }
}
