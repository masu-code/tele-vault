import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:t/t.dart' as t;
import 'package:tg/src/io/byte_sink.dart';
import 'package:tg/src/io/fast_binary_reader.dart';
import 'package:test/test.dart';

Uint8List _rnd(Random r, int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));

int _rnd64(Random r) => (r.nextInt(1 << 32) << 32) | r.nextInt(1 << 32);

String _rndString(Random r) {
  const alphabet = [
    'a',
    'Z',
    '0',
    ' ',
    'ñ',
    'é',
    'ü',
    '日',
    '本',
    '語',
    '😀',
    '🚀'
  ];
  return List.generate(
      r.nextInt(80), (_) => alphabet[r.nextInt(alphabet.length)]).join();
}

List<int> _serialize(t.TlObject o, List<int> sink) {
  o.serialize(sink);
  return sink;
}

/// Deep-normalizes a toJson() tree (nested TlObjects, byte lists as base64) so
/// two results can be compared cheaply. (jsonEncode on these trees hung on a
/// 1.5 KB UploadFile during development, so it is not used here.)
Object? _norm(Object? v) {
  if (v is t.TlObject) return _norm(v.toJson());
  if (v is Uint8List) return base64Encode(v);
  if (v is Map) return {for (final e in v.entries) '${e.key}': _norm(e.value)};
  if (v is Iterable) return [for (final e in v) _norm(e)];
  return v;
}

/// Reads [bytes] with the original and the fast reader, checks both give the
/// same object tree and position, and that re-serializing the result
/// reproduces [bytes].
void _expectSameObject(Uint8List bytes) {
  final orig = t.BinaryReader(Uint8List.fromList(bytes));
  final fast = FastBinaryReader(bytes);
  final a = orig.readObject();
  final b = fast.readObject();
  expect(_norm(b), equals(_norm(a)));
  expect(fast.position, orig.position);
  expect(_serialize(b, <int>[]), bytes);
}

void main() {
  group('FastBinaryReader vs t.BinaryReader', () {
    test('random TL objects round trip identically', () {
      final r = Random(1);
      // Keep the call count of t's giant `_readObject` low: after ~1.5k calls
      // the Dart VM's optimizing compiler stalls on it for minutes (verified:
      // the same loop finishes in 8 s with --optimization-counter-threshold=-1).
      for (var i = 0; i < 30; i++) {
        final objs = <t.TlObject>[
          t.ResPQ(
            nonce: t.Int128(_rnd(r, 16)),
            serverNonce: t.Int128(_rnd(r, 16)),
            pq: _rnd(r, r.nextInt(300)),
            serverPublicKeyFingerprints:
                List.generate(r.nextInt(5), (_) => _rnd64(r)),
          ),
          t.UploadFile(
            type: const t.StorageFileJpeg(),
            mtime: r.nextInt(1 << 31),
            bytes: _rnd(r, r.nextInt(2000)),
          ),
          t.RpcError(errorCode: r.nextInt(600), errorMessage: _rndString(r)),
          t.GeoPoint(
            long: r.nextDouble() * 360 - 180,
            lat: r.nextDouble() * 180 - 90,
            accessHash: _rnd64(r),
            accuracyRadius: r.nextBool() ? r.nextInt(5000) : null,
          ),
          t.MsgsAck(msgIds: List.generate(r.nextInt(20), (_) => _rnd64(r))),
          t.Pong(msgId: _rnd64(r), pingId: _rnd64(r)),
          t.UpdateMessagePollVote(
            pollId: _rnd64(r),
            peer: t.PeerUser(userId: _rnd64(r)),
            options:
                List.generate(r.nextInt(6), (_) => _rnd(r, r.nextInt(300))),
            positions: List.generate(r.nextInt(6), (_) => r.nextInt(1 << 31)),
            qts: r.nextInt(1 << 31),
          ),
          t.PhoneCallProtocol(
            udpP2p: r.nextBool(),
            udpReflector: r.nextBool(),
            minLayer: r.nextInt(200),
            maxLayer: r.nextInt(200),
            libraryVersions: List.generate(r.nextInt(5), (_) => _rndString(r)),
          ),
          t.FutureSalts(
            reqMsgId: _rnd64(r),
            now: r.nextInt(1 << 31),
            salts: List.generate(
              r.nextInt(8),
              (_) => t.FutureSalt(
                validSince: r.nextInt(1 << 31),
                validUntil: r.nextInt(1 << 31),
                salt: _rnd64(r),
              ),
            ),
          ),
        ];
        for (final o in objs) {
          _expectSameObject(Uint8List.fromList(_serialize(o, <int>[])));
        }
      }
    });

    test('bytes of boundary lengths (0/1/253/254/255/1 MiB) incl. padding', () {
      final r = Random(2);
      for (final n in [0, 1, 2, 3, 4, 252, 253, 254, 255, 256, 257, 1 << 20]) {
        final o = t.UploadFile(
            type: const t.StorageFileJpeg(), mtime: 7, bytes: _rnd(r, n));
        final bytes = Uint8List.fromList(_serialize(o, <int>[]));
        _expectSameObject(bytes);
        final fast = FastBinaryReader(bytes)..readObject();
        expect(fast.remaining, 0, reason: 'length $n');
      }
    });

    test('unicode strings (multi-byte, astral)', () {
      final o = t.RpcError(errorCode: 400, errorMessage: 'ñandú 日本語 😀🚀 ü');
      final bytes = Uint8List.fromList(_serialize(o, <int>[]));
      final got = FastBinaryReader(bytes).readObject() as t.RpcError;
      expect(got.errorMessage, 'ñandú 日本語 😀🚀 ü');
    });

    test('primitive reads match, both endiannesses, on a view with offset', () {
      final r = Random(3);
      final raw = _rnd(r, 400);
      final view = Uint8List.sublistView(raw, 37, 37 + 256);
      final a = t.BinaryReader(Uint8List.fromList(view));
      final b = FastBinaryReader(view);
      expect(b.readInt16(), a.readInt16());
      expect(b.readInt16(true), a.readInt16(true));
      expect(b.readInt32(), a.readInt32());
      expect(b.readInt32(true), a.readInt32(true));
      expect(b.readInt64(), a.readInt64());
      expect(b.readInt64(true), a.readInt64(true));
      expect(b.readInt128().data, a.readInt128().data);
      expect(b.readInt256().data, a.readInt256().data);
      expect(b.readFloat64().isNaN, a.readFloat64().isNaN);
      expect(b.readRawBytes(5), a.readRawBytes(5));
      expect(b.position, a.position);
      expect(b.position, 2 + 2 + 4 + 4 + 8 + 8 + 16 + 32 + 8 + 5);
    });

    test('readBytes and readRawBytes return copies', () {
      final src = Uint8List.fromList([3, 1, 2, 3, 0, 0, 0, 0]);
      final fast = FastBinaryReader(src);
      final out = fast.readBytes();
      expect(out, [1, 2, 3]);
      out[0] = 99;
      expect(src[1], 1);
      final raw = FastBinaryReader(src).readRawBytes(3);
      raw[0] = 77;
      expect(src[0], 3);
    });

    test('reading past the end throws RangeError', () {
      final fast = FastBinaryReader(Uint8List.fromList([1, 2, 3]));
      expect(() => fast.readInt32(), throwsRangeError);
      expect(() => FastBinaryReader(Uint8List(5)).readRawBytes(6),
          throwsRangeError);
      expect(() => FastBinaryReader(Uint8List.fromList([5, 1, 2])).readBytes(),
          throwsRangeError);
    });
  });

  group('ByteSink', () {
    test('serialize output equals a plain List<int>', () {
      final r = Random(4);
      final o = t.UploadFile(
          type: const t.StorageFileJpeg(),
          mtime: 1,
          bytes: _rnd(r, 512 * 1024));
      final sink = ByteSink(16);
      o.serialize(sink);
      final plain = _serialize(o, <int>[]);
      expect(sink.length, plain.length);
      expect(sink.takeBytes(), plain);
    });

    test('add/addAll with Uint8List, List<int>, Iterable and views', () {
      final s = ByteSink(16);
      s.add(1);
      s.addAll(Uint8List.fromList([2, 3]));
      s.addAll([4, 5]);
      s.addAll(Iterable<int>.generate(3, (i) => 6 + i));
      s.addAll(
          Uint8List.sublistView(Uint8List.fromList([0, 0, 9, 10, 0]), 2, 4));
      s.addAll(Uint8List(0));
      expect(s.toList(), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(s.length, 10);
    });

    test('grows past capacity, index and length semantics', () {
      final s = ByteSink(16);
      for (var i = 0; i < 1000; i++) {
        s.add(i);
      }
      expect(s.length, 1000);
      expect(s[999], 999 & 0xFF);
      s[0] = 200;
      expect(s[0], 200);
      expect(() => s[1000], throwsRangeError);
      s.length = 4;
      expect(s.length, 4);
      s.length = 6;
      expect(s.sublist(4), [0, 0]);
      s.reserve(1 << 20);
      expect(s.length, 6);
    });

    test('takeBytes detaches: later writes do not alter the returned view', () {
      final s = ByteSink();
      s.addAll([1, 2, 3]);
      final out = s.takeBytes();
      expect(s.length, 0);
      s.addAll([9, 9, 9]);
      expect(out, [1, 2, 3]);
    });
  });
}
