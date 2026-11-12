import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tv_core/codecs.dart';

/// Fake but structurally valid JPEG blob (SOI .. EOI); the pack codec only
/// checks the markers and the CRC.
Uint8List blob(math.Random rnd, int len) {
  final b = Uint8List(len);
  for (var i = 0; i < len; i++) {
    b[i] = rnd.nextInt(256);
  }
  b[0] = 0xFF;
  b[1] = 0xD8;
  b[len - 2] = 0xFF;
  b[len - 1] = 0xD9;
  return b;
}

ThumbPackEntry entry(math.Random rnd, String id, {int? len, String? preview}) =>
    ThumbPackEntry(
      id: id,
      jpeg: blob(rnd, len ?? 200 + rnd.nextInt(2000)),
      width: 200 + rnd.nextInt(120),
      height: 150 + rnd.nextInt(120),
      preview: preview,
    );

final created = DateTime.utc(2026, 11, 11, 12, 30, 45, 123);

Uint8List mutateToc(Uint8List pack, void Function(Map<String, dynamic> toc) f) {
  final bd = ByteData.sublistView(pack);
  final tocLen = bd.getUint32(8, Endian.little);
  final toc = jsonDecode(utf8.decode(pack.sublist(16, 16 + tocLen)))
      as Map<String, dynamic>;
  f(toc);
  final tocBytes = Uint8List.fromList(utf8.encode(jsonEncode(toc)));
  final data = pack.sublist(16 + tocLen);
  final out = Uint8List(16 + tocBytes.length + data.length);
  out.setRange(0, 16, pack);
  final obd = ByteData.sublistView(out);
  obd.setUint32(8, tocBytes.length, Endian.little);
  obd.setUint32(12, crc32(tocBytes), Endian.little);
  out.setRange(16, 16 + tocBytes.length, tocBytes);
  out.setRange(16 + tocBytes.length, out.length, data);
  return out;
}

void main() {
  final rnd = math.Random(42);
  const packId = '0b1c2d3e-aaaa-4bbb-8ccc-1234567890ab';

  group('TVTP round trip', () {
    for (final n in [0, 1, 512]) {
      test('$n entries', () {
        final entries = [
          for (var i = 0; i < n; i++)
            entry(rnd, 'id-$i', len: n == 512 ? 400 : null)
        ];
        final bytes = ThumbPackCodec.encode(
            packId: packId, createdAt: created, entries: entries);
        // Header layout.
        expect(String.fromCharCodes(bytes.sublist(0, 4)), 'TVTP');
        final bd = ByteData.sublistView(bytes);
        expect(bd.getUint16(4, Endian.little), 1);
        expect(bd.getUint16(6, Endian.little), 0);
        final tocLen = bd.getUint32(8, Endian.little);
        expect(bd.getUint32(12, Endian.little),
            crc32(Uint8List.sublistView(bytes, 16, 16 + tocLen)));

        final dec = ThumbPackCodec.decode(bytes);
        expect(dec.packId, packId);
        expect(dec.createdAt, created);
        expect(dec.corruptIds, isEmpty);
        expect(dec.malformedEntries, 0);
        expect(dec.entries.length, n);
        for (var i = 0; i < n; i++) {
          expect(dec.entries[i].id, entries[i].id);
          expect(dec.entries[i].jpeg, entries[i].jpeg);
          expect(dec.entries[i].width, entries[i].width);
          expect(dec.entries[i].height, entries[i].height);
          expect(dec.entries[i].preview, isNull);
        }
      });
    }

    test('previews and unicode ids survive', () {
      final p = PreviewCodec.toWire(PreviewCodec.encodeRgba(
          Uint8List(16 * 16 * 4)..fillRange(0, 1024, 120), 16, 16)!);
      final entries = [
        entry(rnd, 'ñandú-日本-1', preview: p),
        entry(rnd, 'plain'),
      ];
      final dec = ThumbPackCodec.decode(ThumbPackCodec.encode(
          packId: packId, createdAt: created, entries: entries));
      expect(dec.entries[0].id, 'ñandú-日本-1');
      expect(dec.entries[0].preview, p);
      expect(dec.entries[1].preview, isNull);
    });

    test('readToc needs only header + TOC', () {
      final entries = [for (var i = 0; i < 5; i++) entry(rnd, 'e$i')];
      final bytes = ThumbPackCodec.encode(
          packId: packId, createdAt: created, entries: entries);
      final probe = ThumbPackCodec.readToc(bytes);
      final head = Uint8List.sublistView(bytes, 0, probe.dataOffset);
      final toc = ThumbPackCodec.readToc(head);
      expect(toc.entries.length, 5);
      expect(toc.dataOffset, probe.dataOffset);
      // Range-read one entry using the TOC.
      final e = toc.entries[3];
      final slice = bytes.sublist(
          toc.dataOffset + e.offset, toc.dataOffset + e.offset + e.length);
      expect(slice, entries[3].jpeg);
      expect(crc32(slice), e.crc);
    });

    test('caption and file name helpers', () {
      expect(ThumbPackCodec.captionFor(packId), 'TELEVAULT_THUMBS_V1 $packId');
      expect(
          ThumbPackCodec.fileNameFor(packId), 'televault_thumbs_$packId.tvtp');
    });
  });

  group('TVTP encode limits', () {
    test('513 entries rejected', () {
      final entries = [for (var i = 0; i < 513; i++) entry(rnd, 'i$i', len: 8)];
      expect(
          () => ThumbPackCodec.encode(
              packId: packId, createdAt: created, entries: entries),
          throwsA(isA<ThumbPackFormatException>()));
    });

    test('blob over 200 KiB rejected, exactly 200 KiB accepted', () {
      expect(
          () => ThumbPackCodec.encode(
              packId: packId,
              createdAt: created,
              entries: [entry(rnd, 'a', len: 200 * 1024 + 1)]),
          throwsA(isA<ThumbPackFormatException>()));
      final ok = ThumbPackCodec.encode(
          packId: packId,
          createdAt: created,
          entries: [entry(rnd, 'a', len: 200 * 1024)]);
      expect(ThumbPackCodec.decode(ok).entries.single.jpeg.length, 200 * 1024);
    });

    test('total over 8 MiB rejected', () {
      // 41 x 200 KiB = 8.2 MB > 8 MiB (8_388_608); 40 x 200 KiB = 8_192_000 fits.
      final over = [
        for (var i = 0; i < 41; i++) entry(rnd, 'b$i', len: 200 * 1024)
      ];
      expect(
          () => ThumbPackCodec.encode(
              packId: packId, createdAt: created, entries: over),
          throwsA(isA<ThumbPackFormatException>()));
      final fits = [
        for (var i = 0; i < 40; i++) entry(rnd, 'b$i', len: 200 * 1024)
      ];
      expect(
          ThumbPackCodec.decode(ThumbPackCodec.encode(
                  packId: packId, createdAt: created, entries: fits))
              .entries
              .length,
          40);
    });

    test('duplicate ids, non-JPEG, bad dims, bad preview, empty ids rejected',
        () {
      final a = entry(rnd, 'dup');
      void rejects(List<ThumbPackEntry> e, {String id = packId}) => expect(
          () =>
              ThumbPackCodec.encode(packId: id, createdAt: created, entries: e),
          throwsA(isA<ThumbPackFormatException>()));
      rejects([a, a]);
      rejects([
        ThumbPackEntry(
            id: 'x',
            jpeg: Uint8List.fromList([1, 2, 3, 4, 5]),
            width: 1,
            height: 1)
      ]);
      // SOI but no EOI.
      final noEoi = blob(rnd, 50)..[48] = 0;
      rejects([ThumbPackEntry(id: 'x', jpeg: noEoi, width: 1, height: 1)]);
      rejects(
          [ThumbPackEntry(id: 'x', jpeg: blob(rnd, 50), width: 0, height: 1)]);
      rejects([
        ThumbPackEntry(id: 'x', jpeg: blob(rnd, 50), width: 1, height: 70000)
      ]);
      rejects([
        ThumbPackEntry(
            id: 'x',
            jpeg: blob(rnd, 50),
            width: 1,
            height: 1,
            preview: 'th1:AAAA')
      ]);
      rejects(
          [ThumbPackEntry(id: '', jpeg: blob(rnd, 50), width: 1, height: 1)]);
      rejects([a], id: '');
    });
  });

  group('TVTP decode validation', () {
    late Uint8List good;
    late List<ThumbPackEntry> entries;
    setUp(() {
      entries = [for (var i = 0; i < 6; i++) entry(rnd, 'e$i')];
      good = ThumbPackCodec.encode(
          packId: packId, createdAt: created, entries: entries);
    });

    test('corrupt blob byte -> corruptIds, others intact', () {
      final bytes = Uint8List.fromList(good);
      final toc = ThumbPackCodec.readToc(bytes);
      final e = toc.entries[2];
      bytes[toc.dataOffset + e.offset + 10] ^= 0xFF;
      final dec = ThumbPackCodec.decode(bytes);
      expect(dec.corruptIds, ['e2']);
      expect(dec.entries.map((x) => x.id), ['e0', 'e1', 'e3', 'e4', 'e5']);
    });

    test('blob losing its EOI marker -> corruptIds', () {
      final bytes = Uint8List.fromList(good);
      final toc = ThumbPackCodec.readToc(bytes);
      final e = toc.entries[0];
      bytes[toc.dataOffset + e.offset + e.length - 1] = 0;
      expect(ThumbPackCodec.decode(bytes).corruptIds, ['e0']);
    });

    test('truncated data section -> trailing entries corrupt, no throw', () {
      final cut = Uint8List.sublistView(good, 0, good.length - 100);
      final dec = ThumbPackCodec.decode(cut);
      expect(dec.corruptIds, ['e5']);
      expect(dec.entries.length, 5);
    });

    test('bad magic throws', () {
      final b = Uint8List.fromList(good)..[0] = 0x58;
      expect(() => ThumbPackCodec.decode(b),
          throwsA(isA<ThumbPackFormatException>()));
    });

    test('version 2 throws', () {
      final b = Uint8List.fromList(good);
      ByteData.sublistView(b).setUint16(4, 2, Endian.little);
      expect(() => ThumbPackCodec.decode(b),
          throwsA(isA<ThumbPackFormatException>()));
    });

    test('version 0 throws', () {
      final b = Uint8List.fromList(good);
      ByteData.sublistView(b).setUint16(4, 0, Endian.little);
      expect(() => ThumbPackCodec.decode(b),
          throwsA(isA<ThumbPackFormatException>()));
    });

    test('nonzero flags are tolerated', () {
      final b = Uint8List.fromList(good);
      ByteData.sublistView(b).setUint16(6, 0x00FF, Endian.little);
      expect(ThumbPackCodec.decode(b).entries.length, 6);
    });

    test('TOC CRC mismatch throws', () {
      final b = Uint8List.fromList(good)..[20] ^= 0x01; // inside the TOC
      expect(() => ThumbPackCodec.decode(b),
          throwsA(isA<ThumbPackFormatException>()));
      final c = Uint8List.fromList(good);
      c[12] ^= 0xFF; // the stored CRC itself
      expect(() => ThumbPackCodec.decode(c),
          throwsA(isA<ThumbPackFormatException>()));
    });

    test('truncated header / TOC throw', () {
      for (final n in [0, 1, 15]) {
        expect(() => ThumbPackCodec.decode(Uint8List.sublistView(good, 0, n)),
            throwsA(isA<ThumbPackFormatException>()));
      }
      expect(() => ThumbPackCodec.decode(Uint8List.sublistView(good, 0, 30)),
          throwsA(isA<ThumbPackFormatException>()));
    });

    test('absurd tocLen throws instead of allocating', () {
      final b = Uint8List.fromList(good);
      ByteData.sublistView(b).setUint32(8, 0xFFFFFFFF, Endian.little);
      expect(() => ThumbPackCodec.decode(b),
          throwsA(isA<ThumbPackFormatException>()));
    });

    test('wrong TOC format name / TOC version / missing fields throw', () {
      expect(
          () => ThumbPackCodec.decode(
              mutateToc(good, (t) => t['format'] = 'other')),
          throwsA(isA<ThumbPackFormatException>()));
      expect(() => ThumbPackCodec.decode(mutateToc(good, (t) => t['v'] = 2)),
          throwsA(isA<ThumbPackFormatException>()));
      expect(
          () => ThumbPackCodec.decode(
              mutateToc(good, (t) => t.remove('pack_id'))),
          throwsA(isA<ThumbPackFormatException>()));
      expect(
          () => ThumbPackCodec.decode(
              mutateToc(good, (t) => t['created_at'] = 'yesterday')),
          throwsA(isA<ThumbPackFormatException>()));
      expect(
          () =>
              ThumbPackCodec.decode(mutateToc(good, (t) => t['entries'] = 'x')),
          throwsA(isA<ThumbPackFormatException>()));
    });

    test('more than 512 TOC entries throws', () {
      final b = mutateToc(good, (t) {
        final e = (t['entries'] as List).first;
        t['entries'] = List.filled(513, e);
      });
      expect(() => ThumbPackCodec.decode(b),
          throwsA(isA<ThumbPackFormatException>()));
    });

    test(
        'entry with out-of-range / overlapping / oversize fields is corrupt, not thrown',
        () {
      final b = mutateToc(good, (t) {
        final es = t['entries'] as List;
        (es[1] as Map)['off'] = 0; // overlaps e0
        (es[2] as Map)['len'] = 200 * 1024 + 1; // oversize
        (es[3] as Map)['crc'] = -5;
        (es[4] as Map)['w'] = 'wide';
      });
      final dec = ThumbPackCodec.decode(b);
      expect(dec.corruptIds.toSet(), {'e1', 'e2', 'e3', 'e4'});
      expect(dec.entries.map((e) => e.id), ['e0', 'e5']);
    });

    test('entry pointing past the data end is corrupt', () {
      final b = mutateToc(good, (t) {
        final es = t['entries'] as List;
        (es[5] as Map)['off'] = 7 * 1024 * 1024;
      });
      expect(ThumbPackCodec.decode(b).corruptIds, ['e5']);
    });

    test('repeated or missing ids count as malformed entries', () {
      final b = mutateToc(good, (t) {
        final es = t['entries'] as List;
        (es[1] as Map)['id'] = 'e0';
        (es[2] as Map).remove('id');
        es.add('junk');
      });
      final dec = ThumbPackCodec.decode(b);
      expect(dec.malformedEntries, 3);
      expect(dec.corruptIds, isEmpty);
      expect(dec.entries.map((e) => e.id), ['e0', 'e3', 'e4', 'e5']);
    });

    test('bad preview in the TOC drops the preview, keeps the thumbnail', () {
      final b = mutateToc(good, (t) {
        ((t['entries'] as List)[0] as Map)['p'] = 'th1:AAAA';
      });
      final dec = ThumbPackCodec.decode(b);
      expect(dec.corruptIds, isEmpty);
      expect(dec.entries.first.preview, isNull);
    });

    test('fuzz: random mutations only ever throw ThumbPackFormatException', () {
      final r = math.Random(2026);
      for (var n = 0; n < 1500; n++) {
        final b = Uint8List.fromList(good);
        for (var k = 0; k < 1 + r.nextInt(6); k++) {
          b[r.nextInt(b.length)] = r.nextInt(256);
        }
        final cut = r.nextBool()
            ? b
            : Uint8List.sublistView(b, 0, r.nextInt(b.length + 1));
        try {
          final dec = ThumbPackCodec.decode(cut);
          expect(
              dec.entries.length + dec.corruptIds.length + dec.malformedEntries,
              lessThanOrEqualTo(6));
        } on ThumbPackFormatException {
          // expected
        }
      }
    });
  });
}
