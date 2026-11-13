import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tele_vault/core/metadata/capture_date_probe.dart';
import 'package:tele_vault/core/metadata/capture_date_recovery.dart';
import 'package:tele_vault/core/metadata/exif_date.dart';
import 'package:tele_vault/core/metadata/mp4_date.dart';
import 'package:tele_vault/core/thumbnail/backfill_service.dart' show BackfillIndexAccess;
import 'package:tele_vault/models/capture_date.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

// ------------------------------------------------------------------ EXIF

const _tagDateTime = 0x0132;
const _tagOriginal = 0x9003;
const _tagDigitized = 0x9004;

/// A TIFF block with ASCII date tags in IFD0 and (when any) an Exif IFD.
Uint8List _tiff(Map<int, String> ifd0, Map<int, String> exif, {Endian endian = Endian.little}) {
  final hasExif = exif.isNotEmpty;
  final n0 = ifd0.length + (hasExif ? 1 : 0);
  const ifd0At = 8;
  final exifAt = ifd0At + 2 + 12 * n0 + 4;
  var dataAt = exifAt + (hasExif ? 2 + 12 * exif.length + 4 : 0);
  final b = ByteData(dataAt + 20 * (ifd0.length + exif.length));
  final mark = endian == Endian.little ? 0x49 : 0x4D;
  b.setUint8(0, mark);
  b.setUint8(1, mark);
  b.setUint16(2, 42, endian);
  b.setUint32(4, ifd0At, endian);

  void writeIfd(int at, Map<int, String> ascii, {int? exifPointer}) {
    final tags = ascii.keys.toList()..sort();
    final count = tags.length + (exifPointer != null ? 1 : 0);
    b.setUint16(at, count, endian);
    var e = at + 2;
    for (final tag in tags) {
      b.setUint16(e, tag, endian);
      b.setUint16(e + 2, 2, endian);
      b.setUint32(e + 4, 20, endian);
      b.setUint32(e + 8, dataAt, endian);
      final s = ascii[tag]!;
      for (var k = 0; k < s.length && k < 19; k++) {
        b.setUint8(dataAt + k, s.codeUnitAt(k));
      }
      dataAt += 20;
      e += 12;
    }
    if (exifPointer != null) {
      b.setUint16(e, 0x8769, endian);
      b.setUint16(e + 2, 4, endian);
      b.setUint32(e + 4, 1, endian);
      b.setUint32(e + 8, exifPointer, endian);
      e += 12;
    }
    b.setUint32(e, 0, endian);
  }

  writeIfd(ifd0At, ifd0, exifPointer: hasExif ? exifAt : null);
  if (hasExif) writeIfd(exifAt, exif);
  return b.buffer.asUint8List();
}

/// SOI, a JFIF APP0, an Exif APP1 holding [tiff], SOS and some scan bytes.
Uint8List _jpegWith(Uint8List tiff) {
  final app1Len = 2 + 6 + tiff.length;
  return Uint8List.fromList([
    0xFF, 0xD8,
    0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 1, 1, 0, 0, 1, 0, 1, 0, 0,
    0xFF, 0xE1, app1Len >> 8, app1Len & 0xFF, 0x45, 0x78, 0x69, 0x66, 0, 0,
    ...tiff,
    0xFF, 0xDA, 0x00, 0x08, 1, 2, 3, 4, 5, 6,
    ...List.filled(64, 0x55),
    0xFF, 0xD9,
  ]);
}

int _local(int y, int mo, int d, int h, int mi, int s) =>
    DateTime(y, mo, d, h, mi, s).millisecondsSinceEpoch;

// ------------------------------------------------------------------- MP4

Uint8List _box(String type, List<int> payload) {
  final b = BytesBuilder();
  final size = 8 + payload.length;
  b.add([size >> 24 & 0xFF, size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF]);
  b.add(ascii.encode(type));
  b.add(payload);
  return b.toBytes();
}

/// An `mvhd` full box whose creation_time is [secs] since 1904.
Uint8List _mvhd(int version, int secs) {
  final body = ByteData(version == 1 ? 108 : 96);
  body.setUint8(0, version);
  if (version == 1) {
    body.setUint64(4, secs);
    body.setUint64(12, secs);
    body.setUint32(20, 1000);
  } else {
    body.setUint32(4, secs);
    body.setUint32(8, secs);
    body.setUint32(12, 1000);
  }
  return _box('mvhd', body.buffer.asUint8List());
}

const int _epoch1904 = 2082844800;
final int _when = DateTime.utc(2021, 6, 15, 10, 30, 45).millisecondsSinceEpoch;
int get _whenSecs1904 => _when ~/ 1000 + _epoch1904;

final Uint8List _ftyp = _box('ftyp', ascii.encode('isom\x00\x00\x02\x00isomiso2mp41'));

/// A document of [size] bytes made of [segments] (offset -> bytes), zeros
/// elsewhere; records every ranged read.
class _SparseDoc {
  _SparseDoc(this.size, this.segments);
  final int size;
  final Map<int, Uint8List> segments;
  final List<(int, int)> reads = [];

  Future<Uint8List> read(int offset, int limit) async {
    reads.add((offset, limit));
    final end = math.min(offset + limit, size);
    if (offset >= end) return Uint8List(0);
    final out = Uint8List(end - offset);
    segments.forEach((at, bytes) {
      final from = math.max(at, offset);
      final to = math.min(at + bytes.length, end);
      if (from < to) out.setRange(from - offset, to - offset, bytes, from - at);
    });
    return out;
  }
}

_SparseDoc _contiguous(List<Uint8List> boxes) {
  final all = BytesBuilder();
  for (final b in boxes) {
    all.add(b);
  }
  final bytes = all.toBytes();
  return _SparseDoc(bytes.length, {0: bytes});
}

void _expectLegalReads(_SparseDoc doc) {
  for (final (offset, limit) in doc.reads) {
    expect(offset % 4096, 0, reason: 'offset $offset not 4 KB aligned');
    expect((1024 * 1024) % limit, 0, reason: 'limit $limit does not divide 1 MB');
    expect(offset ~/ (1024 * 1024), (offset + limit - 1) ~/ (1024 * 1024),
        reason: 'read crosses a 1 MB boundary');
  }
}

// ------------------------------------------------------------------- job

FileItem _item(String id, String mime, {String? name, int size = 500000, int parts = 1}) => FileItem(
      id: id,
      name: name ?? 'h4sh${id}xq.${mime.split('/').last}',
      folderId: null,
      totalSize: size * parts,
      mimeType: mime,
      createdAt: DateTime(2026, 11, 1),
      parts: [
        for (var i = 0; i < parts; i++) FilePart(messageId: 1000 + id.hashCode % 100000 + i, part: i, size: size),
      ],
    );

class _FakeIndex implements BackfillIndexAccess {
  _FakeIndex(this.index);
  FileIndex index;
  int writes = 0;
  void Function()? beforeWrite;

  @override
  FileIndex? current() => index;

  @override
  Future<FileIndex> write(FileIndex Function(FileIndex current) mutate) async {
    beforeWrite?.call();
    final next = mutate(index);
    if (!identical(next, index)) {
      writes++;
      index = next;
    }
    return index;
  }
}

class _FakeRemote implements CaptureDateRemote {
  _FakeRemote(this.answer);
  final CaptureProbeResult Function(CaptureProbeTarget t) answer;
  final List<String> probed = [];
  int calls = 0;
  void Function(int call)? onCall;

  @override
  Future<List<CaptureProbeResult>> probe(List<CaptureProbeTarget> targets) async {
    calls++;
    onCall?.call(calls);
    probed.addAll(targets.map((t) => t.id));
    return [for (final t in targets) answer(t)];
  }
}

final int _ms = DateTime(2019, 3, 4, 5, 6, 7).millisecondsSinceEpoch;

CaptureProbeResult _dated(CaptureProbeTarget t) =>
    CaptureProbeResult(t.id, CaptureProbeStatus.dated, ms: _ms, bytes: 1000);

void main() {
  group('EXIF', () {
    final original = _local(2021, 6, 15, 10, 30, 45);

    test('reads DateTimeOriginal (little and big endian) as local time', () {
      for (final endian in [Endian.little, Endian.big]) {
        final jpeg = _jpegWith(_tiff(
          {_tagDateTime: '2023:01:01 00:00:00'},
          {_tagOriginal: '2021:06:15 10:30:45', _tagDigitized: '2022:02:02 02:02:02'},
          endian: endian,
        ));
        expect(jpegExifCaptureMs(jpeg), original);
      }
    });

    test('falls back to DateTimeDigitized, then DateTime', () {
      expect(
        jpegExifCaptureMs(_jpegWith(_tiff(
          {_tagDateTime: '2023:01:01 00:00:00'},
          {_tagOriginal: '0000:00:00 00:00:00', _tagDigitized: '2022:02:02 02:02:02'},
        ))),
        _local(2022, 2, 2, 2, 2, 2),
      );
      expect(
        jpegExifCaptureMs(_jpegWith(_tiff({_tagDateTime: '2023:01:01 00:00:00'}, const {}))),
        _local(2023, 1, 1, 0, 0, 0),
      );
    });

    test('implausible, invalid or missing dates give null', () {
      expect(jpegExifCaptureMs(_jpegWith(_tiff({_tagDateTime: '1995:01:01 00:00:00'}, const {}))),
          isNull);
      expect(jpegExifCaptureMs(_jpegWith(_tiff({_tagDateTime: '2021:02:30 00:00:00'}, const {}))),
          isNull);
      expect(jpegExifCaptureMs(_jpegWith(_tiff({_tagDateTime: '2099:01:01 00:00:00'}, const {}))),
          isNull);
      expect(jpegExifCaptureMs(_jpegWith(_tiff(const {}, const {}))), isNull);
      expect(jpegExifCaptureMs(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isNull);
      expect(jpegExifCaptureMs(Uint8List(0)), isNull);
    });

    test('a truncated header never throws and uses what is there', () {
      final jpeg = _jpegWith(_tiff(
        {_tagDateTime: '2023:01:01 00:00:00'},
        {_tagOriginal: '2021:06:15 10:30:45'},
      ));
      for (var cut = 0; cut <= jpeg.length; cut++) {
        final ms = jpegExifCaptureMs(Uint8List.sublistView(jpeg, 0, cut));
        expect(ms == null || ms == original || ms == _local(2023, 1, 1, 0, 0, 0), isTrue);
      }
      expect(jpegExifCaptureMs(jpeg), original);
    });

    test('probeCaptureDate reads 128 KB of a JPEG at offset 0', () async {
      final jpeg = _jpegWith(_tiff(const {}, {_tagOriginal: '2021:06:15 10:30:45'}));
      final doc = _SparseDoc(3 * 1024 * 1024, {0: jpeg});
      final r = await probeCaptureDate(
          const CaptureProbeTarget('a', 1, CaptureKind.jpeg), doc.size, doc.read);
      expect(r.status, CaptureProbeStatus.dated);
      expect(r.ms, original);
      expect(doc.reads, [(0, kJpegHeaderWindow)]);
      _expectLegalReads(doc);
    });
  });

  group('MP4 mvhd', () {
    test('creation_time v0 (32-bit) and v1 (64-bit)', () {
      for (final v in [0, 1]) {
        final body = Uint8List.sublistView(_mvhd(v, _whenSecs1904), 8);
        expect(mvhdCreationMs(body), _when, reason: 'version $v');
      }
    });

    test('creation_time 0, pre-2000 or future is no date', () {
      for (final v in [0, 1]) {
        expect(mvhdCreationMs(Uint8List.sublistView(_mvhd(v, 0), 8)), isNull);
        expect(mvhdCreationMs(Uint8List.sublistView(_mvhd(v, _epoch1904 + 100), 8)), isNull);
      }
      final future = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
      expect(mvhdCreationMs(Uint8List.sublistView(_mvhd(1, future + _epoch1904), 8)), isNull);
    });

    test('moov at the start: one window', () async {
      final doc = _contiguous([
        _ftyp,
        _box('moov', _mvhd(0, _whenSecs1904)),
        _box('mdat', Uint8List(300000)),
      ]);
      final r = await mp4CreationMs(doc.read, doc.size);
      expect(r.outcome, Mp4DateOutcome.dated);
      expect(r.ms, _when);
      expect(r.windows, 1);
      _expectLegalReads(doc);
    });

    test('moov at the end: mdat size leads to the window holding it', () async {
      final doc = _contiguous([
        _ftyp,
        _box('free', Uint8List(8)),
        _box('mdat', Uint8List(700000)),
        _box('moov', [..._box('udta', Uint8List(16)), ..._mvhd(1, _whenSecs1904)]),
      ]);
      final r = await mp4CreationMs(doc.read, doc.size);
      expect(r.outcome, Mp4DateOutcome.dated);
      expect(r.ms, _when);
      expect(r.windows, 2);
      expect(doc.reads.first.$1, 0);
      _expectLegalReads(doc);
    });

    test('64-bit mdat size: moov past 4 GB in a sparse document', () async {
      const mdatSize = 5000000000;
      final mdatAt = _ftyp.length;
      final header = ByteData(16)
        ..setUint32(0, 1)
        ..setUint8(4, 0x6D)
        ..setUint8(5, 0x64)
        ..setUint8(6, 0x61)
        ..setUint8(7, 0x74)
        ..setUint64(8, mdatSize);
      final moov = _box('moov', _mvhd(1, _whenSecs1904));
      final moovAt = mdatAt + mdatSize;
      final doc = _SparseDoc(moovAt + moov.length, {
        0: _ftyp,
        mdatAt: header.buffer.asUint8List(),
        moovAt: moov,
      });
      final r = await mp4CreationMs(doc.read, doc.size);
      expect(r.outcome, Mp4DateOutcome.dated);
      expect(r.ms, _when);
      expect(r.windows, 2);
      _expectLegalReads(doc);
    });

    test('moov with creation_time 0 at the end is no date', () async {
      final doc = _contiguous([_ftyp, _box('mdat', Uint8List(200000)), _box('moov', _mvhd(0, 0))]);
      final r = await mp4CreationMs(doc.read, doc.size);
      expect(r.outcome, Mp4DateOutcome.noDate);
      expect(r.ms, isNull);
    });

    test('at most 3 windows per file', () async {
      final doc = _contiguous([
        _ftyp,
        _box('mdat', Uint8List(100000)),
        _box('free', Uint8List(100000)),
        _box('skip', Uint8List(100000)),
        _box('moov', _mvhd(0, _whenSecs1904)),
      ]);
      final r = await mp4CreationMs(doc.read, doc.size);
      expect(r.outcome, Mp4DateOutcome.noDate);
      expect(r.windows, 3);
      expect(doc.reads, hasLength(3));
      _expectLegalReads(doc);
    });

    test('not an ISO BMFF file is unsupported; moov past the first part too', () async {
      final junk = _SparseDoc(10000, {0: Uint8List.fromList(List.filled(64, 0xFF))});
      expect((await mp4CreationMs(junk.read, junk.size)).outcome, Mp4DateOutcome.unsupported);

      // The first part ends inside mdat: moov is in a later part.
      final first = _contiguous([_ftyp, _box('mdat', Uint8List(150000))]);
      final cut = _SparseDoc(100000, first.segments);
      final r = await mp4CreationMs(cut.read, cut.size, multiPart: true);
      expect(r.outcome, Mp4DateOutcome.unsupported);
    });
  });

  group('recovery job', () {
    late Directory dir;
    late CaptureRecoveryStateStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tv_capture_');
      store = CaptureRecoveryStateStore(() async => dir);
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    CaptureDateRecoveryService service(_FakeIndex index, CaptureDateRemote remote,
            {bool requireUnmetered = false, bool network = true}) =>
        CaptureDateRecoveryService(
          index: index,
          remote: remote,
          stateStore: store,
          requireUnmetered: requireUnmetered,
          networkAllowed: () async => network,
        );

    test('candidates: media dated by upload time only', () {
      final index = FileIndex(files: [
        _item('a', 'image/jpeg'),
        _item('b', 'video/mp4'),
        _item('c', 'image/heic'),
        _item('named', 'image/jpeg', name: 'IMG_20240105_142233.jpg'),
        withTakenAt(_item('stamped', 'image/jpeg'), _ms),
        _item('doc', 'application/pdf'),
      ]);
      expect(CaptureDateRecoveryService.candidatesOf(index).map((f) => f.id), ['a', 'b', 'c']);
    });

    test('plan counts only and never calls Telegram', () async {
      final remote = _FakeRemote(_dated);
      final index = _FakeIndex(FileIndex(files: [
        _item('a', 'image/jpeg', size: 50000),
        _item('b', 'image/jpeg'),
        _item('v', 'video/quicktime'),
        _item('h', 'image/heic'),
        _item('png', 'image/png'),
      ]));
      final plan = await service(index, remote).plan();
      expect(plan.candidates, 5);
      expect(plan.photos, 2);
      expect(plan.videos, 1);
      expect(plan.unsupported, 2);
      expect(plan.estimatedBytes, 50000 + kJpegHeaderWindow + 3 * kMp4Window);
      expect(remote.calls, 0);
      expect(index.writes, 0);
    });

    test('writes the index once at the end, not every 100 dates', () async {
      final files = [for (var i = 0; i < 250; i++) _item('p$i', 'image/jpeg')];
      final index = _FakeIndex(FileIndex(files: files));
      final remote = _FakeRemote(_dated);
      final result = await service(index, remote).run();
      expect(index.writes, 1);
      expect(result.dated, 250);
      expect(result.written, 250);
      for (final f in index.index.files) {
        expect(f.extra[takenAtKey], _ms);
      }
      expect(remote.probed.toSet(), hasLength(250));
    });

    test('no dates found: no index write', () async {
      final index = _FakeIndex(FileIndex(files: [for (var i = 0; i < 30; i++) _item('p$i', 'video/mp4')]));
      final remote = _FakeRemote((t) => CaptureProbeResult(t.id, CaptureProbeStatus.noDate));
      final result = await service(index, remote).run();
      expect(index.writes, 0);
      expect(result.noDate, 30);
    });

    test('never overwrites a taken_at stored meanwhile', () async {
      final index = _FakeIndex(FileIndex(files: [_item('a', 'image/jpeg'), _item('b', 'image/jpeg')]));
      const other = 1600000000000;
      index.beforeWrite = () {
        index.index = index.index.copyWith(files: [
          for (final f in index.index.files) f.id == 'a' ? withTakenAt(f, other) : f,
        ]);
      };
      await service(index, _FakeRemote(_dated)).run();
      final byId = {for (final f in index.index.files) f.id: f};
      expect(byId['a']!.extra[takenAtKey], other);
      expect(byId['b']!.extra[takenAtKey], _ms);
    });

    test('unsupported formats are settled without a download', () async {
      final index = _FakeIndex(FileIndex(files: [
        _item('h', 'image/heic'),
        _item('png', 'image/png'),
        _item('a', 'image/jpeg'),
      ]));
      final remote = _FakeRemote(_dated);
      final result = await service(index, remote).run();
      expect(remote.probed, ['a']);
      expect(result.unsupported, 2);
      expect(result.dated, 1);
    });

    test('resume skips processed items; errors are retried', () async {
      final files = [for (var i = 0; i < 60; i++) _item('p$i', 'image/jpeg')];
      final index = _FakeIndex(FileIndex(files: files));
      final remote = _FakeRemote((t) => t.id == 'p0'
          ? CaptureProbeResult(t.id, CaptureProbeStatus.error)
          : t.id == 'p1'
              ? CaptureProbeResult(t.id, CaptureProbeStatus.noDate)
              : _dated(t));
      final job = service(index, remote);
      remote.onCall = (n) {
        if (n == 1) job.pause();
      };
      final first = await job.run();
      expect(first.phase, CaptureRecoveryPhase.paused);
      final firstProbed = remote.probed.toSet();
      expect(firstProbed.length, lessThan(60));
      expect(index.writes, 1);

      remote.probed.clear();
      remote.onCall = null;
      // A fresh service (as after an app restart) reads the state file.
      final second = await service(index, remote).run();
      expect(second.phase, CaptureRecoveryPhase.done);
      final secondProbed = remote.probed.toSet();
      // Only p0 (error) is probed again; everything else probed once in all.
      expect(secondProbed.intersection(firstProbed), {'p0'});
      expect(firstProbed.union(secondProbed), hasLength(60));
      final stamped = index.index.files.where(hasStoredTakenAt).map((f) => f.id).toSet();
      expect(stamped, {for (var i = 2; i < 60; i++) 'p$i'});

      // Nothing left: a third run probes nothing and writes nothing.
      remote.probed.clear();
      final writes = index.writes;
      await service(index, remote).run();
      expect(remote.probed, ['p0']);
      expect(index.writes, writes);
    });

    test('dates in the state file but not in the index are written without probing', () async {
      final index = _FakeIndex(FileIndex(files: [_item('a', 'image/jpeg'), _item('b', 'image/jpeg')]));
      await store.save(CaptureRecoveryState(done: {'a': 'dated'}, dated: {'a': _ms}));
      final remote = _FakeRemote((t) => CaptureProbeResult(t.id, CaptureProbeStatus.noDate));
      await service(index, remote).run();
      expect(remote.probed, ['b']);
      expect(index.writes, 1);
      expect(index.index.files.firstWhere((f) => f.id == 'a').extra[takenAtKey], _ms);
      final saved = jsonDecode(File(p.join(dir.path, CaptureRecoveryStateStore.fileName))
          .readAsStringSync()) as Map<String, dynamic>;
      expect((saved['done'] as Map)['b'], 'noDate');
    });

    test('needs an unmetered network when required', () async {
      final index = _FakeIndex(FileIndex(files: [_item('a', 'image/jpeg')]));
      final remote = _FakeRemote(_dated);
      await expectLater(
        service(index, remote, requireUnmetered: true, network: false).run(),
        throwsA(isA<CaptureRecoveryBlockedException>()),
      );
      expect(remote.calls, 0);
      expect(index.writes, 0);
    });
  });

  test('owned sources: no deletes, no uploads, no names or paths in logs', () {
    final files = [
      ...Directory('lib/core/metadata')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => f.path),
      'lib/features/profile/providers/maintenance_provider.dart',
    ];
    expect(files.length, greaterThanOrEqualTo(5));
    final forbidden = [
      'delete' 'Messages',
      'saveFile' 'Part',
      'saveBigFile' 'Part',
      'send' 'Media',
      'send' 'Message',
      'edit' 'Message',
      'upload' 'Media',
      'upload' 'Pack',
    ];
    for (final path in files) {
      final src = File(path).readAsStringSync();
      for (final word in forbidden) {
        expect(src.contains(word), isFalse, reason: '$path contains $word');
      }
      if (path.contains('metadata')) {
        expect(src.contains('.delete('), isFalse, reason: path);
      }
      for (final line in const LineSplitter().convert(src)) {
        final logs = line.contains('print(') || line.contains('_log(');
        if (!logs) continue;
        for (final word in ['.name', 'path', 'caption', 'fileName', r'$e']) {
          expect(line.contains(word), isFalse, reason: '$path: $line');
        }
      }
    }
  });
}
