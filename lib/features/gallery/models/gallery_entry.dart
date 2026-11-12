import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:photo_manager/photo_manager.dart';
import '../../../models/capture_date.dart';
import '../../../models/file_item.dart';

/// One row in the unified Gallery timeline: a device asset, a cloud
/// [FileItem], or both (when the same photo/video is on-device AND already
/// uploaded). At least one of [asset]/[fileItem] is always non-null.
class GalleryEntry {
  /// [thumbKey] may be passed when the caller already has it; otherwise it is
  /// derived from [asset]/[fileItem]. The date is always derived here (see
  /// [effectiveDateMs]): it is the one key the feed sorts by AND the month
  /// sections group by, so no caller can hand in a different one.
  GalleryEntry({
    this.asset,
    this.fileItem,
    String? thumbKey,
  }) : assert(asset != null || fileItem != null),
       effectiveDateMs = asset != null
           ? deviceCaptureMs(asset) ?? 0
           : cloudCaptureMs(fileItem!),
       thumbKey =
           thumbKey ??
           (fileItem != null
               ? fileItem.id
               : deviceThumbKey(asset!.id, asset.modifiedDateSecond ?? 0));

  final AssetEntity? asset;
  final FileItem? fileItem;

  /// When the photo/video was taken, as epoch milliseconds, computed once.
  /// The single key for sorting AND month grouping:
  ///  * with a device asset: its capture date (MediaStore DATE_TAKEN, or the
  ///    file-name date when they differ by more than 36 h; see
  ///    [deviceCaptureMs]);
  ///  * cloud-only: the capture date recorded at upload, else the date in
  ///    the file name, else the upload time (see [cloudCaptureMs]).
  final int effectiveDateMs;

  /// Key of this entry in the thumbnail store: the cloud file id when the
  /// entry has a cloud item, else a hash of the device asset id plus its
  /// modified time (so an edited photo gets a fresh thumbnail).
  final String thumbKey;

  /// Stable identity for selection sets and widget keys.
  String get key => asset?.id ?? fileItem!.id;

  bool get isUploaded => fileItem != null;
  bool get isOnDevice => asset != null;

  bool get isVideo => fileItem != null
      ? fileItem!.mimeType.startsWith('video/')
      : asset!.type == AssetType.video;

  /// [effectiveDateMs] as a local DateTime, built once on first read.
  late final DateTime effectiveDate =
      DateTime.fromMillisecondsSinceEpoch(effectiveDateMs);
}

/// One month section of the timeline, newest first.
class GalleryMonthGroup {
  const GalleryMonthGroup({required this.month, required this.entries});

  /// Normalized to the 1st of the month, local time.
  final DateTime month;
  final List<GalleryEntry> entries;
}

final Expando<List<GalleryMonthGroup>> _groupsByList = Expando();

/// Buckets [sorted] (must already be sorted by [GalleryEntry.effectiveDateMs]
/// descending) into month sections in a single pass. The result is cached by
/// list identity, so [sorted] must not be mutated after the call (the feed
/// builds a new list instead of editing one).
List<GalleryMonthGroup> groupEntriesByMonth(List<GalleryEntry> sorted) {
  return _groupsByList[sorted] ??= _groupEntriesByMonth(sorted);
}

List<GalleryMonthGroup> _groupEntriesByMonth(List<GalleryEntry> sorted) {
  final groups = <GalleryMonthGroup>[];
  final byMonth = <DateTime, List<GalleryEntry>>{};
  DateTime? currentMonth;
  List<GalleryEntry>? currentEntries;
  var duplicateGroups = 0;

  for (final entry in sorted) {
    final local = entry.effectiveDate;
    final month = DateTime(local.year, local.month);
    if (currentMonth != month) {
      currentMonth = month;
      final seen = byMonth[month];
      if (seen != null) {
        // Cannot happen while the list is sorted by the same key it is grouped
        // by; if it ever does, one section per month (sliver keys are months).
        duplicateGroups++;
        currentEntries = seen;
      } else {
        currentEntries = byMonth[month] = [];
        groups.add(GalleryMonthGroup(month: month, entries: currentEntries));
      }
    }
    currentEntries!.add(entry);
  }
  if (duplicateGroups > 0) {
    debugPrint('TVDIAG: gallery duplicate month group '
        '(reappeared=$duplicateGroups, groups=${groups.length}, '
        'entries=${sorted.length})');
  }
  return groups;
}

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "October 2026" — English, matching the rest of the app's UI.
String monthLabel(DateTime month) =>
    '${_monthNames[month.month - 1]} ${month.year}';

/// Section-header label: "November" for the current year, "June 2025" for any
/// other (Google Photos style). [monthLabel] keeps the year for the scrollbar.
String monthHeaderLabel(DateTime month, int currentYear) =>
    month.year == currentYear
    ? _monthNames[month.month - 1]
    : monthLabel(month);

final Map<String, String> _deviceKeyCache = {};

/// Thumbnail-store key of a device-only asset:
/// `a_<first 20 hex chars of sha1(assetId)>_<modifiedSec>`.
String deviceThumbKey(String assetId, int modifiedSec) {
  final hash = _deviceKeyCache[assetId] ??= _sha1Hex(
    utf8.encode(assetId),
  ).substring(0, 20);
  return 'a_${hash}_$modifiedSec';
}

/// SHA-1 hex digest. Local so the app does not need `package:crypto` as a
/// direct dependency just to name a cache file.
String _sha1Hex(List<int> message) {
  int rotl(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xFFFFFFFF;

  final bitLen = message.length * 8;
  final padded = List<int>.of(message)..add(0x80);
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLen >> (i * 8)) & 0xFF);
  }

  var h0 = 0x67452301;
  var h1 = 0xEFCDAB89;
  var h2 = 0x98BADCFE;
  var h3 = 0x10325476;
  var h4 = 0xC3D2E1F0;
  final w = List<int>.filled(80, 0);

  for (var off = 0; off < padded.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] =
          (padded[off + i * 4] << 24) |
          (padded[off + i * 4 + 1] << 16) |
          (padded[off + i * 4 + 2] << 8) |
          padded[off + i * 4 + 3];
    }
    for (var i = 16; i < 80; i++) {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var i = 0; i < 80; i++) {
      int f, k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xFFFFFFFF) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final temp = (rotl(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
  }
  return [
    h0,
    h1,
    h2,
    h3,
    h4,
  ].map((h) => h.toRadixString(16).padLeft(8, '0')).join();
}

/// Exposed for tests only.
String sha1HexForTesting(List<int> message) => _sha1Hex(message);
