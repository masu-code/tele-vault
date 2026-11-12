import 'package:photo_manager/photo_manager.dart' show AssetEntity;

import 'file_index.dart';
import 'file_item.dart';

/// Key in [FileItem.extra] (so in the index JSON) holding the photo's capture
/// time as epoch milliseconds. Optional: indexes written before it existed
/// load unchanged, and app versions that do not know it keep it verbatim
/// through `FileItem.extra` without reading it.
const String takenAtKey = 'taken_at';

/// The [FileItem.extra] entry recording [takenAtMs], or an empty map when it
/// is unknown (null or not positive).
Map<String, dynamic> takenAtExtra(int? takenAtMs) =>
    takenAtMs != null && takenAtMs > 0 ? {takenAtKey: takenAtMs} : const {};

final Expando<int> _captureMsCache = Expando('captureMs');
final Expando<int> _deviceCaptureMsCache = Expando('deviceCaptureMs');

/// When the file-name date and the stored/device date disagree by more than
/// this, the name wins: a device without EXIF falls back to the date the file
/// was added (a migration day), while the name still says when it was shot.
const Duration _nameDateWinsAfter = Duration(hours: 36);

/// [ms] when it is a believable capture time (2000-01-01 .. [now] + 1 day),
/// else null. A garbage MediaStore/index value (clock set to 2036, a value in
/// nanoseconds) must never reach grouping, where it would throw or put a
/// bogus section on top. [now] is for tests.
int? plausibleCaptureMs(num? ms, {DateTime? now}) {
  if (ms == null || !ms.isFinite) return null;
  final min = DateTime(2000).millisecondsSinceEpoch;
  final max = (now ?? DateTime.now())
      .add(const Duration(days: 1))
      .millisecondsSinceEpoch;
  if (ms < min || ms > max) return null;
  return ms.toInt();
}

/// The capture time to use given a [rawMs] (stored `taken_at` or device date;
/// null/implausible are ignored) and the file [name]: the plausible [rawMs],
/// unless the name carries a plausible date more than 36 h away from it (then
/// the name's), or the name's date alone when [rawMs] is unusable; null when
/// neither is. [now] is for tests.
int? resolveCaptureMs(num? rawMs, String? name, {DateTime? now}) {
  final raw = plausibleCaptureMs(rawMs, now: now);
  final fromName = name == null ? null : captureDateFromName(name, now: now);
  if (raw == null) return fromName;
  if (fromName != null &&
      (fromName - raw).abs() > _nameDateWinsAfter.inMilliseconds) {
    return fromName;
  }
  return raw;
}

/// When the photo/video of cloud item [f] was taken, as epoch milliseconds:
///
/// 1. the [takenAtKey] recorded at upload time, unless the file-name date
///    (see [captureDateFromName]) is more than 36 h away, then the name's;
/// 2. else the date in its file name;
/// 3. else [FileItem.createdAt], which is the upload time.
///
/// Stored values that are not plausible (see [plausibleCaptureMs]) are
/// skipped. Computed once per [FileItem] instance (cached by identity), so
/// rebuilding the gallery feed never re-parses a name it has already seen.
int cloudCaptureMs(FileItem f) {
  final cached = _captureMsCache[f];
  if (cached != null) return cached;
  final ms = resolveCaptureMs(_storedTakenAt(f), f.name) ??
      f.createdAt.millisecondsSinceEpoch;
  _captureMsCache[f] = ms;
  return ms;
}

/// When device [asset] was taken, as epoch ms, with the same rules as
/// [cloudCaptureMs] (plausibility bounds; a file-name date more than 36 h
/// from the device date wins); null when neither the device nor the name
/// gives a believable date. Cached per [AssetEntity] instance.
int? deviceCaptureMs(AssetEntity asset) {
  final cached = _deviceCaptureMsCache[asset];
  if (cached != null) return cached > 0 ? cached : null;
  // Bound the seconds before multiplying so a nanosecond-sized value cannot
  // overflow while being converted to milliseconds.
  final s = asset.createDateSecond;
  final raw = s != null && s > 0 && s < 100000000000 ? s * 1000 : null;
  final ms = resolveCaptureMs(raw, asset.title);
  _deviceCaptureMsCache[asset] = ms ?? 0;
  return ms;
}

num? _storedTakenAt(FileItem f) {
  final v = f.extra[takenAtKey];
  return v is num && v > 0 ? v : null;
}

/// True when [f] carries a usable stored [takenAtKey] (positive number).
bool hasStoredTakenAt(FileItem f) => _storedTakenAt(f) != null;

/// True when [cloudCaptureMs] of [f] falls back to [FileItem.createdAt] (the
/// upload time): no believable stored date and no date in its name.
bool datedByUploadTime(FileItem f) =>
    resolveCaptureMs(_storedTakenAt(f), f.name) == null;

/// [f] with [takenAtKey] set to [takenAtMs]; every other field unchanged.
FileItem withTakenAt(FileItem f, int takenAtMs) =>
    f.withExtra(takenAtKey, takenAtMs);

/// [index] with [takenAtKey] set from [msById] (file id -> epoch ms) on every
/// listed file that has no stored value yet. A stored value is never
/// overwritten, and an implausible one in [msById] is skipped. Returns
/// [index] itself when nothing changes (so `applyAndSave` writes nothing).
FileIndex stampTakenAt(FileIndex index, Map<String, int> msById) {
  if (msById.isEmpty) return index;
  var changed = false;
  final files = <FileItem>[];
  for (final f in index.files) {
    final ms = msById[f.id];
    if (ms != null && plausibleCaptureMs(ms) != null && !hasStoredTakenAt(f)) {
      files.add(withTakenAt(f, ms));
      changed = true;
    } else {
      files.add(f);
    }
  }
  return changed ? index.copyWith(files: files) : index;
}

// IMG_20240105_142233, VID_..., PXL_20240105_142233123, MVIMG_..., PANO_...,
// Screenshot_20240105-142233, and the bare Samsung 20240105_142233.
final RegExp _compactName = RegExp(
  r'^(?:(?:IMG|VID|PXL|MVIMG|PANO|Screenshot)[_-])?'
  r'(\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})',
  caseSensitive: false,
);

// WhatsApp on Android: IMG-20240105-WA0012 (date only).
final RegExp _whatsAppCompactName = RegExp(
  r'^(?:IMG|VID)-(\d{4})(\d{2})(\d{2})-WA\d',
  caseSensitive: false,
);

// Screenshot_2024-01-05-14-22-33-..., signal-2024-01-05-142233...,
// WhatsApp Image 2024-01-05 at 14.22.33 (optionally "2.22.33 PM").
final RegExp _dashedName = RegExp(
  r'^(?:Screenshot|signal|WhatsApp (?:Image|Video))[ _-]+'
  r'(\d{4})-(\d{2})-(\d{2})'
  r'(?:[ _-]+(?:at[ ]+)?(\d{1,2})[.\-]?(\d{2})[.\-]?(\d{2})(?:[ ]?([AP]M))?)?',
  caseSensitive: false,
);

/// The capture time encoded in a camera/app file [name] (local wall-clock
/// time, as cameras write it), as epoch milliseconds; null when the name has
/// no recognized date or the date is not plausible (before 2000, in the
/// future, or not a real calendar date). [now] is for tests.
int? captureDateFromName(String name, {DateTime? now}) {
  int? at(RegExpMatch m, int i) {
    final s = m.group(i);
    return s == null ? null : int.parse(s);
  }

  int? result;
  var m = _compactName.firstMatch(name);
  if (m != null) {
    result = _plausible(at(m, 1)!, at(m, 2)!, at(m, 3)!, at(m, 4)!, at(m, 5)!,
        at(m, 6)!, now);
  } else if ((m = _whatsAppCompactName.firstMatch(name)) != null) {
    result = _plausible(at(m!, 1)!, at(m, 2)!, at(m, 3)!, 0, 0, 0, now);
  } else if ((m = _dashedName.firstMatch(name)) != null) {
    var hour = at(m!, 4) ?? 0;
    final ampm = m.group(7)?.toUpperCase();
    if (ampm != null) {
      if (hour < 1 || hour > 12) return null;
      hour = hour % 12 + (ampm == 'PM' ? 12 : 0);
    }
    result = _plausible(at(m, 1)!, at(m, 2)!, at(m, 3)!, hour, at(m, 5) ?? 0,
        at(m, 6) ?? 0, now);
  }
  return result;
}

int? _plausible(int y, int mo, int d, int h, int mi, int s, DateTime? now) {
  if (y < 2000 || mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  if (h > 23 || mi > 59 || s > 59) return null;
  final t = DateTime(y, mo, d, h, mi, s);
  // DateTime rolls Feb 30 over into March: reject instead.
  if (t.year != y || t.month != mo || t.day != d) return null;
  final ms = t.millisecondsSinceEpoch;
  if (ms > (now ?? DateTime.now()).millisecondsSinceEpoch) return null;
  return ms;
}
