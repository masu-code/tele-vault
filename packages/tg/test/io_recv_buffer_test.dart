import 'dart:math';
import 'dart:typed_data';

import 'package:tg/src/io/recv_buffer.dart';
import 'package:tg/tg.dart' show AesCtr;
import 'package:test/test.dart';

Uint8List _rnd(Random r, int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));

/// Wire bytes of [bodies]: LE int32 length + body per frame, all passed
/// through one CTR stream (as the obfuscated transport does).
Uint8List _wire(List<Uint8List> bodies, AesCtr ctr) {
  final out = BytesBuilder();
  for (final b in bodies) {
    final frame = Uint8List(4 + b.length);
    ByteData.sublistView(frame).setInt32(0, b.length, Endian.little);
    frame.setRange(4, frame.length, b);
    ctr.encryptDecrypt(frame, frame.length);
    out.add(frame);
  }
  return out.takeBytes();
}

/// Feeds [wire] to a RecvBuffer in the given chunk sizes and drains frames
/// the way the transformer will: peek the length, then take the frame.
List<Uint8List> _drain(Uint8List wire, Iterable<int> chunkSizes, AesCtr ctr) {
  final buf = RecvBuffer(16);
  final frames = <Uint8List>[];
  var pos = 0;
  final sizes = chunkSizes.iterator;
  while (pos < wire.length) {
    final n = sizes.moveNext() ? sizes.current : wire.length;
    final end = min(pos + n, wire.length);
    buf.add(Uint8List.sublistView(wire, pos, end));
    pos = end;
    while (true) {
      final len =
          buf.peekLengthDecrypted((four) => ctr.encryptDecrypt(four, 4));
      if (len == null) break;
      final body = buf.takeFrame(len);
      if (body == null) break;
      ctr.encryptDecrypt(body, body.length);
      frames.add(body);
    }
  }
  return frames;
}

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i * 3 + 1));
  final iv = Uint8List.fromList(List.generate(16, (i) => 255 - i));
  late Random r;
  late List<Uint8List> bodies;

  setUp(() {
    r = Random(7);
    bodies = [
      _rnd(r, 0),
      _rnd(r, 1),
      _rnd(r, 20),
      _rnd(r, 4096),
      _rnd(r, 17),
      _rnd(r, 100000),
      _rnd(r, 4),
    ];
  });

  void expectFrames(List<Uint8List> got) {
    expect(got.length, bodies.length);
    for (var i = 0; i < bodies.length; i++) {
      expect(got[i], bodies[i], reason: 'frame $i');
    }
  }

  test('one-byte chunks', () {
    final wire = _wire(bodies, AesCtr(key, iv));
    expectFrames(_drain(
        wire, Iterable.generate(wire.length + 1, (_) => 1), AesCtr(key, iv)));
  });

  test('chunks spanning several frames and splitting length headers', () {
    final wire = _wire(bodies, AesCtr(key, iv));
    for (final pattern in [
      [3],
      [4],
      [5, 1, 7],
      [1000],
      [65536],
      [wire.length],
    ]) {
      final sizes = Iterable.generate(
          wire.length + 1, (i) => pattern[i % pattern.length]);
      expectFrames(_drain(wire, sizes, AesCtr(key, iv)));
    }
  });

  test('random chunk sizes', () {
    final wire = _wire(bodies, AesCtr(key, iv));
    for (var round = 0; round < 20; round++) {
      final rr = Random(round);
      final sizes =
          Iterable.generate(wire.length + 1, (_) => 1 + rr.nextInt(9000));
      expectFrames(_drain(wire, sizes, AesCtr(key, iv)));
    }
  });

  test('peek decrypts the length only once and is stable until takeFrame', () {
    final ctr = AesCtr(key, iv);
    final wire = _wire([
      Uint8List.fromList([1, 2, 3])
    ], AesCtr(key, iv));
    final buf = RecvBuffer(16);
    expect(buf.peekLengthDecrypted((_) => fail('too early')), isNull);
    buf.add(wire.sublist(0, 2));
    expect(buf.peekLengthDecrypted((_) => fail('too early')), isNull);
    buf.add(wire.sublist(2, 5));
    var calls = 0;
    int? first;
    first = buf.peekLengthDecrypted((four) {
      calls++;
      ctr.encryptDecrypt(four, 4);
    });
    expect(first, 3);
    expect(buf.peekLengthDecrypted((_) => fail('must be cached')), 3);
    expect(calls, 1);
    expect(buf.takeFrame(3), isNull, reason: 'body incomplete');
    expect(buf.length, 5);
    buf.add(wire.sublist(5));
    final body = buf.takeFrame(3)!;
    ctr.encryptDecrypt(body, 3);
    expect(body, [1, 2, 3]);
    expect(buf.length, 0);
  });

  test('taken frames are copies; buffer reuse does not corrupt them', () {
    final buf = RecvBuffer(16);
    final f1 = Uint8List.fromList([4, 0, 0, 0, 1, 2, 3, 4]);
    buf.add(f1);
    final body = buf.takeFrame(buf.peekLengthDecrypted((_) {})!)!;
    buf.add(Uint8List.fromList([4, 0, 0, 0, 9, 9, 9, 9]));
    expect(body, [1, 2, 3, 4]);
  });

  test('compacts when the consumed prefix frees enough room', () {
    final buf = RecvBuffer(64);
    for (var i = 0; i < 1000; i++) {
      final body = Uint8List.fromList(List.filled(40, i & 0xFF));
      final frame = Uint8List(44);
      ByteData.sublistView(frame).setInt32(0, 40, Endian.little);
      frame.setRange(4, 44, body);
      buf.add(frame);
      final len = buf.peekLengthDecrypted((_) {})!;
      expect(buf.takeFrame(len), body);
    }
    expect(buf.length, 0);
  });

  test('negative length is rejected', () {
    expect(() => RecvBuffer().takeFrame(-1), throwsArgumentError);
  });
}
