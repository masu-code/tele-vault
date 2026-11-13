import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/capture_date.dart' show plausibleCaptureMs;

/// Reads up to [limit] bytes of a document starting at [offset]; returns
/// fewer (or none) at the end of the document.
typedef RangeReader = Future<Uint8List> Function(int offset, int limit);

/// Bytes per ranged read of a video. Divides 1 MB, and every read starts at a
/// multiple of it, so `upload.getFile`'s rules (offset a multiple of 4 KB,
/// limit dividing 1 MB, no read across a 1 MB boundary) always hold.
const int kMp4Window = 64 * 1024;

/// Most windows read per video.
const int kMp4MaxWindows = 3;

/// Seconds from 1904-01-01 (the ISO BMFF / QuickTime epoch) to 1970-01-01.
const int _mp4EpochOffsetSec = 2082844800;

/// Most top-level boxes (or `moov` children) walked before giving up.
const int _maxBoxes = 64;

enum Mp4DateOutcome {
  /// `mvhd.creation_time` gave a plausible time.
  dated,

  /// The file was read but carries no usable date (no `moov`/`mvhd` within
  /// the window budget, creation_time 0 or implausible, malformed boxes).
  noDate,

  /// Not an ISO BMFF / QuickTime file, or its `moov` lies past the first
  /// Telegram document of a multi-part item.
  unsupported,
}

class Mp4DateResult {
  const Mp4DateResult(this.outcome, {this.ms, required this.windows, required this.bytesRead});
  final Mp4DateOutcome outcome;
  final int? ms;

  /// Ranged reads made and bytes they returned.
  final int windows;
  final int bytesRead;
}

/// The `creation_time` of the `mvhd` full box whose body (from the version
/// byte on) is [body], as epoch ms; null when it is 0, before 1904, not
/// plausible (see [plausibleCaptureMs]) or [body] is too short. Version 0
/// stores it as 32-bit seconds, version 1 as 64-bit, both since 1904-01-01
/// UTC. [now] is for tests.
int? mvhdCreationMs(Uint8List body, {DateTime? now}) {
  if (body.isEmpty) return null;
  final d = ByteData.sublistView(body);
  final version = body[0];
  int secs;
  if (version == 1) {
    if (body.length < 12) return null;
    secs = d.getUint64(4);
  } else if (version == 0) {
    if (body.length < 8) return null;
    secs = d.getUint32(4);
  } else {
    return null;
  }
  if (secs <= _mp4EpochOffsetSec) return null; // 0 / unset / before 1970
  final unix = secs - _mp4EpochOffsetSec;
  if (unix > 100000000000) return null; // would overflow as ms
  return plausibleCaptureMs(unix * 1000, now: now);
}

/// The capture time of an MP4/MOV/3GP document of [size] bytes, read
/// through [read] in [window]-sized, [window]-aligned ranges (at most
/// [maxWindows]).
///
/// Walks the top-level boxes from the start; when `moov` is not in the first
/// window, the box sizes (`mdat` included, 64-bit sizes too) say where it
/// starts, and only the window(s) holding its first bytes are read. Then
/// `moov`'s children are walked to `mvhd`. [multiPart] says [size] is only
/// the first part of a larger file: a `moov` past it counts as unsupported.
Future<Mp4DateResult> mp4CreationMs(
  RangeReader read,
  int size, {
  bool multiPart = false,
  int window = kMp4Window,
  int maxWindows = kMp4MaxWindows,
  DateTime? now,
}) async {
  final w = _Windows(read, size, window, maxWindows);
  Mp4DateResult done(Mp4DateOutcome o, [int? ms]) =>
      Mp4DateResult(o, ms: ms, windows: w.fetched, bytesRead: w.bytes);

  try {
    var pos = 0;
    for (var n = 0; n < _maxBoxes && pos + 8 <= size; n++) {
      final box = await w.box(pos, size);
      if (box == null) return done(Mp4DateOutcome.noDate);
      if (n == 0 && !_isFourCc(box.type)) return done(Mp4DateOutcome.unsupported);
      if (box.type == 'moov') {
        final ms = await _moovCreationMs(w, pos + box.header, math.min(pos + box.size, size), now);
        return done(ms == null ? Mp4DateOutcome.noDate : Mp4DateOutcome.dated, ms);
      }
      pos += box.size;
    }
    if (multiPart && pos >= size) return done(Mp4DateOutcome.unsupported);
    return done(Mp4DateOutcome.noDate);
  } on _OutOfBudget {
    return done(Mp4DateOutcome.noDate);
  }
}

Future<int?> _moovCreationMs(_Windows w, int start, int end, DateTime? now) async {
  var c = start;
  for (var n = 0; n < _maxBoxes && c + 8 <= end; n++) {
    final box = await w.box(c, end);
    if (box == null) return null;
    if (box.type == 'mvhd') {
      final bodyAt = c + box.header;
      final len = math.min(12, end - bodyAt);
      if (len < 8) return null;
      final body = await w.get(bodyAt, len);
      return body == null ? null : mvhdCreationMs(body, now: now);
    }
    c += box.size;
  }
  return null;
}

bool _isFourCc(String type) =>
    type.length == 4 && type.codeUnits.every((c) => c >= 0x20 && c < 0x7F);

class _Box {
  const _Box(this.type, this.size, this.header);
  final String type;
  final int size;
  final int header;
}

class _OutOfBudget implements Exception {
  const _OutOfBudget();
}

/// Ranged reads of one document, cached per aligned window and capped.
class _Windows {
  _Windows(this._read, this._size, this._window, this._max);
  final RangeReader _read;
  final int _size;
  final int _window;
  final int _max;
  final Map<int, Uint8List> _got = {};
  int fetched = 0;
  int bytes = 0;

  /// The box header at [pos] (whose box must end by [end]); null when it is
  /// malformed or past the document.
  Future<_Box?> box(int pos, int end) async {
    final h = await get(pos, 8);
    if (h == null) return null;
    final d = ByteData.sublistView(h);
    var size = d.getUint32(0);
    final type = String.fromCharCodes(h, 4, 8);
    var header = 8;
    if (size == 1) {
      final large = await get(pos + 8, 8);
      if (large == null) return null;
      size = ByteData.sublistView(large).getUint64(0);
      header = 16;
    } else if (size == 0) {
      size = end - pos; // extends to the end of its container
    }
    if (size < header) return null;
    return _Box(type, size, header);
  }

  /// Bytes [a, a + n) of the document; null when they are not all there.
  /// Throws [_OutOfBudget] when a needed window would exceed the cap.
  Future<Uint8List?> get(int a, int n) async {
    if (a < 0 || n <= 0 || a + n > _size) return null;
    final out = Uint8List(n);
    var pos = a;
    while (pos < a + n) {
      final start = pos - pos % _window;
      var data = _got[start];
      if (data == null) {
        if (fetched >= _max) throw const _OutOfBudget();
        fetched++;
        data = await _read(start, _window);
        bytes += data.length;
        _got[start] = data;
      }
      final inWindow = pos - start;
      if (inWindow >= data.length) return null; // short read
      final take = math.min(data.length - inWindow, a + n - pos);
      out.setRange(pos - a, pos - a + take, data, inWindow);
      pos += take;
    }
    return out;
  }
}
