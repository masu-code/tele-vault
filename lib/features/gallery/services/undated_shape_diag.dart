import 'package:flutter/foundation.dart' show debugPrint;
import '../../../models/capture_date.dart';
import '../models/gallery_entry.dart';

final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _digit = RegExp(r'\p{Nd}', unicode: true);

/// Longest shape kept; longer ones end in `+`.
const int _maxShapeLength = 64;

/// The SHAPE of a file [name], never the name itself: every letter becomes
/// `A`, every digit `9`, runs of either collapse to one, ASCII punctuation
/// and spaces are kept, any other character becomes `?`. A short extension
/// (1-5 letters/digits after the last dot) is kept as `.A`.
/// `IMG_20240105_142233.jpg` -> `A_9_9.A`, `20240105.mp4` -> `9.A`.
String nameShape(String name) {
  final dot = name.lastIndexOf('.');
  final extLength = name.length - dot - 1;
  if (dot > 0 &&
      extLength >= 1 &&
      extLength <= 5 &&
      _extension.hasMatch(name.substring(dot + 1))) {
    return '${_shape(name.substring(0, dot))}.A';
  }
  return _shape(name);
}

final RegExp _extension = RegExp(r'^[A-Za-z0-9]+$');

String _shape(String name) {
  final b = StringBuffer();
  String? last;
  for (final r in name.runes) {
    final ch = String.fromCharCode(r);
    final String cls;
    if (_letter.hasMatch(ch)) {
      cls = 'A';
    } else if (_digit.hasMatch(ch)) {
      cls = '9';
    } else if (r >= 0x20 && r < 0x7f) {
      cls = ch;
    } else {
      cls = '?';
    }
    if ((cls == 'A' || cls == '9') && cls == last) continue;
    if (b.length >= _maxShapeLength) {
      b.write('+');
      break;
    }
    b.write(cls);
    last = cls;
  }
  return b.toString();
}

/// Diagnostic lines (counts only, no names) for the cloud-only entries of
/// [entries] whose date falls back to the upload time: the [top] most common
/// [nameShape]s, then the total.
List<String> undatedShapeReport(List<GalleryEntry> entries, {int top = 15}) {
  final counts = <String, int>{};
  var cloudOnly = 0, undated = 0;
  for (final e in entries) {
    final f = e.fileItem;
    if (e.asset != null || f == null) continue;
    cloudOnly++;
    // Cheap filter first: only an entry showing its upload time can be one.
    if (e.effectiveDateMs != f.createdAt.millisecondsSinceEpoch ||
        !datedByUploadTime(f)) {
      continue;
    }
    undated++;
    final shape = nameShape(f.name);
    counts[shape] = (counts[shape] ?? 0) + 1;
  }
  final ranked = counts.entries.toList()
    ..sort((a, b) =>
        a.value != b.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));
  return [
    for (final e in ranked.take(top)) 'TVDIAG: undated shape ${e.key} n=${e.value}',
    'TVDIAG: undated total=$undated of $cloudOnly',
  ];
}

bool _logged = false;

/// Prints [undatedShapeReport] once per app start.
void logUndatedShapesOnce(List<GalleryEntry> entries) {
  if (_logged) return;
  _logged = true;
  for (final line in undatedShapeReport(entries)) {
    debugPrint(line);
  }
}
