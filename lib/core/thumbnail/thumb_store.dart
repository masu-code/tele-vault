import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show FileImage;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Builds the key a thumbnail is stored under.
///
/// A key is the cloud `FileItem.id` whenever the entry has a cloud item (so a
/// photo keeps the same thumbnail before and after it is uploaded from another
/// device), otherwise `a_<hex(sha1(assetId))[0:20]>_<modifiedSec>` for a
/// device-only asset. The modification time is part of the key so an edited
/// photo gets a fresh thumbnail.
abstract final class ThumbKey {
  static String forEntry({String? fileId, String? assetId, int? assetModifiedSec}) {
    if (fileId != null) return fileId;
    if (assetId == null) {
      throw ArgumentError('Either fileId or assetId is required.');
    }
    return 'a_${sha1Hex(assetId).substring(0, 20)}_${assetModifiedSec ?? 0}';
  }

  static final RegExp _safe = RegExp(r'^[A-Za-z0-9_\-]{1,80}$');

  /// Keys become file names (`<key>.jpg`); anything that could escape the
  /// thumbnail directory or collide with the bookkeeping files is refused.
  /// `FileItem.id` values are uuids and device keys are `a_<hex>_<digits>`.
  static bool isSafe(String key) => _safe.hasMatch(key);

  /// Device-asset keys: the evictable ones (a cloud copy can always rebuild a
  /// cloud-key thumbnail, a device one would be regenerated from the asset).
  static bool isDeviceKey(String key) => key.startsWith('a_');

  /// Lowercase hex SHA-1 of the UTF-8 bytes of [input]. Not used for security:
  /// only to derive a short, stable, file-name-safe key from an asset id.
  @visibleForTesting
  static String sha1Hex(String input) {
    final msg = Uint8List.fromList(utf8.encode(input));
    final padded = _pad(msg);
    final w = Uint32List(80);
    var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    const mask = 0xFFFFFFFF;
    int rotl(int v, int n) => ((v << n) | (v >> (32 - n))) & mask;
    final bd = ByteData.sublistView(padded);
    for (var off = 0; off < padded.length; off += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = bd.getUint32(off + i * 4);
      }
      for (var i = 16; i < 80; i++) {
        w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4;
      for (var i = 0; i < 80; i++) {
        int f, k;
        if (i < 20) {
          f = (b & c) | ((~b & mask) & d);
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
        final tmp = (rotl(a, 5) + f + e + k + w[i]) & mask;
        e = d;
        d = c;
        c = rotl(b, 30);
        b = a;
        a = tmp;
      }
      h0 = (h0 + a) & mask;
      h1 = (h1 + b) & mask;
      h2 = (h2 + c) & mask;
      h3 = (h3 + d) & mask;
      h4 = (h4 + e) & mask;
    }
    return [h0, h1, h2, h3, h4].map((v) => v.toRadixString(16).padLeft(8, '0')).join();
  }

  static Uint8List _pad(Uint8List msg) {
    final bitLen = msg.length * 8;
    var total = msg.length + 1;
    while (total % 64 != 56) {
      total++;
    }
    final out = Uint8List(total + 8);
    out.setRange(0, msg.length, msg);
    out[msg.length] = 0x80;
    final bd = ByteData.sublistView(out);
    bd.setUint32(total, bitLen ~/ 0x100000000);
    bd.setUint32(total + 4, bitLen & 0xFFFFFFFF);
    return out;
  }
}

/// True when [b] looks like a complete JPEG (SOI at the start, EOI at the end).
bool looksLikeJpeg(Uint8List b) =>
    b.length >= 4 &&
    b[0] == 0xFF &&
    b[1] == 0xD8 &&
    b[b.length - 2] == 0xFF &&
    b[b.length - 1] == 0xD9;

/// The one on-disk thumbnail directory (`<appSupport>/televault_thumbs/<key>.jpg`)
/// shared by device and cloud tiles, the viewer and the explorer.
///
/// Startup costs one directory listing (in a background isolate): no file is
/// opened or decoded. A damaged file is found when something fails to decode
/// it and reported with [reportCorrupt].
///
/// Without a usable application-support directory (widget tests have no
/// path_provider) [init] throws, [isReady] stays false and every other member
/// is a harmless no-op.
class ThumbStore {
  ThumbStore._(this._resolveDir) : _maxBytes = defaultMaxBytes;

  /// A store over a caller-provided directory (tests).
  @visibleForTesting
  ThumbStore.withDirectory(Future<Directory> Function() resolveDir, {int? maxBytes})
      : _resolveDir = resolveDir,
        _maxBytes = maxBytes ?? defaultMaxBytes;

  static final ThumbStore instance = ThumbStore._(_defaultDir);

  /// Device-key thumbnails are evicted (oldest first) when the directory grows
  /// past this many bytes. Cloud-key thumbnails are never evicted.
  static const int defaultMaxBytes = 400 * 1024 * 1024;

  /// Largest JPEG [put] accepts.
  static const int maxJpegBytes = 512 * 1024;

  /// Minimum spacing between [revision] bumps.
  static const Duration _revisionInterval = Duration(milliseconds: 250);

  static Future<Directory> _defaultDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'televault_thumbs'));
    await dir.create(recursive: true);
    return dir;
  }

  final Future<Directory> Function() _resolveDir;
  final int _maxBytes;

  final Set<String> _keys = <String>{};
  Directory? _dir;
  Future<void>? _init;
  bool _ready = false;
  int _tmpCounter = 0;

  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  Timer? _revisionTimer;
  DateTime _lastBump = DateTime.fromMillisecondsSinceEpoch(0);

  /// Bumped (at most 4 times a second) whenever a thumbnail appears or
  /// disappears. Tiles whose file is still missing listen to this.
  ValueListenable<int> get revision => _revision;

  bool get isReady => _ready;

  /// Idempotent. Lists the directory once on a helper isolate, deleting
  /// leftover `*.tmp` and 0-byte files and trimming device thumbnails over the
  /// size budget, then remembers which keys exist.
  Future<void> init() => _init ??= _doInit();

  Future<void> _doInit() async {
    try {
      final dir = await _resolveDir();
      await dir.create(recursive: true);
      final path = dir.path;
      final budget = _maxBytes;
      final keys = await Isolate.run(() => _scanThumbDir(path, budget));
      _dir = dir;
      _keys
        ..clear()
        ..addAll(keys);
      _ready = true;
    } catch (_) {
      // Leave `_init` completed-with-error so every caller sees the failure;
      // [isReady] stays false and the store behaves as empty.
      _ready = false;
      rethrow;
    }
  }

  /// Absolute path of the thumbnail directory. Throws when unavailable.
  Future<String> dirPath() async {
    await init();
    return _dir!.path;
  }

  bool has(String key) => _keys.contains(key);

  /// The thumbnail file for [key] if it is known to exist, else null.
  File? fileIfPresent(String key) {
    final dir = _dir;
    if (dir == null || !_keys.contains(key)) return null;
    return File(p.join(dir.path, '$key.jpg'));
  }

  /// Number of thumbnails known to exist (diagnostics, tests).
  int get length => _keys.length;

  /// Stores [jpeg] under [key]: tmp file + rename, so a reader never sees a
  /// half-written thumbnail. Returns false (storing nothing) for an unsafe key,
  /// bytes that are not a complete JPEG, more than [maxJpegBytes], or a store
  /// that is not usable.
  Future<bool> put(String key, Uint8List jpeg) async {
    if (!ThumbKey.isSafe(key) || !looksLikeJpeg(jpeg) || jpeg.length > maxJpegBytes) {
      return false;
    }
    try {
      await init();
    } catch (_) {
      return false;
    }
    final dir = _dir;
    if (dir == null) return false;
    final file = File(p.join(dir.path, '$key.jpg'));
    final tmp = File('${file.path}.${_tmpCounter++}.tmp');
    try {
      await tmp.writeAsBytes(jpeg);
      await tmp.rename(file.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return false;
    }
    _keys.add(key);
    _evictFromImageCache(file);
    _bump();
    return true;
  }

  /// Records keys whose files were written by another isolate (pack install on
  /// the download worker). Files must already be in place.
  void markPresent(Iterable<String> keys) {
    var changed = false;
    for (final k in keys) {
      if (ThumbKey.isSafe(k) && _keys.add(k)) changed = true;
    }
    if (changed) _bump();
  }

  /// A decode of [key]'s file failed: delete it and forget the key so it is
  /// fetched again.
  Future<void> reportCorrupt(String key) async {
    final dir = _dir;
    if (dir == null) return;
    final removed = _keys.remove(key);
    final file = File(p.join(dir.path, '$key.jpg'));
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _evictFromImageCache(file);
    if (removed) _bump();
  }

  void _evictFromImageCache(File file) {
    try {
      unawaited(FileImage(file).evict().catchError((Object _) => false));
    } catch (_) {
      // No painting binding (pure unit tests).
    }
  }

  void _bump() {
    final now = DateTime.now();
    final since = now.difference(_lastBump);
    if (_revisionTimer == null && since >= _revisionInterval) {
      _lastBump = now;
      _revision.value++;
      return;
    }
    _revisionTimer ??= Timer(
      since >= _revisionInterval ? Duration.zero : _revisionInterval - since,
      () {
        _revisionTimer = null;
        _lastBump = DateTime.now();
        _revision.value++;
      },
    );
  }

  /// Test hook: forget everything and allow [init] to run again.
  @visibleForTesting
  void resetForTesting() {
    _revisionTimer?.cancel();
    _revisionTimer = null;
    _keys.clear();
    _dir = null;
    _init = null;
    _ready = false;
  }
}

/// Runs on a helper isolate: one directory listing + stats, no file reads.
List<String> _scanThumbDir(String path, int maxBytes) {
  final dir = Directory(path);
  if (!dir.existsSync()) return const <String>[];
  final files = <({String key, int size, int modifiedMs, bool device})>[];
  var total = 0;
  for (final e in dir.listSync(followLinks: false)) {
    if (e is! File) continue;
    final name = p.basename(e.path);
    if (name.endsWith('.tmp')) {
      try {
        e.deleteSync();
      } catch (_) {}
      continue;
    }
    if (!name.endsWith('.jpg')) continue;
    final key = name.substring(0, name.length - 4);
    if (!ThumbKey.isSafe(key)) continue;
    final stat = e.statSync();
    if (stat.size == 0) {
      try {
        e.deleteSync();
      } catch (_) {}
      continue;
    }
    total += stat.size;
    files.add((
      key: key,
      size: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
      device: ThumbKey.isDeviceKey(key),
    ));
  }
  if (total > maxBytes) {
    final evictable = files.where((f) => f.device).toList()
      ..sort((a, b) => a.modifiedMs.compareTo(b.modifiedMs));
    final gone = <String>{};
    for (final f in evictable) {
      if (total <= maxBytes) break;
      try {
        File(p.join(path, '${f.key}.jpg')).deleteSync();
        total -= f.size;
        gone.add(f.key);
      } catch (_) {}
    }
    files.removeWhere((f) => gone.contains(f.key));
  }
  return [for (final f in files) f.key];
}
