import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tv_core/codecs.dart';

import '../../models/file_item.dart';

/// key -> ThumbHash (20-25 bytes), the tiny placeholder a tile paints before
/// its thumbnail file exists. One table for device and cloud tiles.
///
/// Persisted as an append-only file, `<appSupport>/tv_previews.bin`, of
/// records `u8 keyLen | key utf8 | u8 hashLen | hash` (the last record of a key
/// wins). It is loaded whole at [init] (10k items is about 0.6 MB) and
/// compacted when the file is more than twice the size of the live data.
///
/// Reads are synchronous and served from memory. Without a usable file
/// location (widget tests) the table is memory-only and nothing throws.
class PreviewTable {
  PreviewTable._(this._resolveFile);

  /// A table persisted at a caller-provided file (tests).
  @visibleForTesting
  PreviewTable.withFile(Future<File> Function() resolveFile) : _resolveFile = resolveFile;

  static final PreviewTable instance = PreviewTable._(_defaultFile);

  static Future<File> _defaultFile() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'tv_previews.bin'));
  }

  final Future<File> Function() _resolveFile;
  final Map<String, Uint8List> _hashes = <String, Uint8List>{};
  final Map<String, int?> _average = <String, int?>{};

  File? _file;
  Future<void>? _init;
  int _liveBytes = 0;
  int _fileBytes = 0;
  Future<void> _io = Future<void>.value();

  /// Compaction needs at least this much dead space, so tiny tables are not
  /// rewritten over and over.
  static const int _minDeadBytes = 4096;

  /// Idempotent. Never throws: on any failure the table works in memory only.
  Future<void> init() => _init ??= _doInit();

  Future<void> _doInit() async {
    try {
      final file = await _resolveFile();
      await file.parent.create(recursive: true);
      var valid = 0;
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        valid = _parse(bytes, Set<String>.of(_hashes.keys));
        if (valid > 0) _bump(); // tiles built before the load finished
        if (valid < bytes.length) {
          // A torn last record (killed mid-append): cut it off, or the next
          // append would land after garbage and misalign every later record.
          final raf = await file.open(mode: FileMode.append);
          try {
            await raf.truncate(valid);
          } finally {
            await raf.close();
          }
        }
      }
      _fileBytes = valid;
      _file = file;
    } catch (_) {
      _file = null; // memory-only
    }
  }

  /// Loads records from [bytes]; returns the length of the valid prefix.
  int _parse(Uint8List bytes, Set<String> newerInMemory) {
    var i = 0;
    while (i < bytes.length) {
      final keyLen = bytes[i];
      if (keyLen == 0 || i + 1 + keyLen + 1 > bytes.length) break;
      final hashLenAt = i + 1 + keyLen;
      final hashLen = bytes[hashLenAt];
      final end = hashLenAt + 1 + hashLen;
      if (hashLen == 0 || end > bytes.length) break;
      final String key;
      try {
        key = utf8.decode(Uint8List.sublistView(bytes, i + 1, hashLenAt));
      } catch (_) {
        break;
      }
      // An entry put before the file was loaded is newer than anything in it;
      // within the file the last record of a key wins.
      if (!newerInMemory.contains(key)) {
        final old = _hashes[key];
        if (old != null) _liveBytes -= _recordSize(key, old.length);
        _hashes[key] = Uint8List.fromList(
          Uint8List.sublistView(bytes, hashLenAt + 1, end),
        );
        _liveBytes += _recordSize(key, hashLen);
      }
      i = end;
    }
    return i;
  }

  static int _recordSize(String key, int hashLen) =>
      1 + utf8.encode(key).length + 1 + hashLen;

  /// The ThumbHash for [key], or null.
  Uint8List? hash(String key) => _hashes[key];

  /// The average colour of [key]'s preview as 0xAARRGGBB, or null.
  int? averageArgb(String key) {
    if (_average.containsKey(key)) return _average[key];
    final h = _hashes[key];
    if (h == null) return null;
    return _average[key] = PreviewCodec.averageArgb(PreviewCodec.toWire(h));
  }

  int get length => _hashes.length;

  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  bool _bumpQueued = false;

  /// Bumped once per batch of changes ([put], [putAll], [importFromIndex]);
  /// puts made in the same microtask share one bump. Tiles that wait for a
  /// preview listen to it.
  ValueListenable<int> get revision => _revision;

  void _bump() {
    if (_bumpQueued) return;
    _bumpQueued = true;
    scheduleMicrotask(() {
      _bumpQueued = false;
      _revision.value++;
    });
  }

  /// Stores [hash] for [key] (memory now, file queued). Invalid input is
  /// ignored.
  void put(String key, Uint8List hash) => _putAll({key: hash});

  /// Stores many entries with a single append.
  void putAll(Map<String, Uint8List> entries) => _putAll(entries);

  /// Imports every `FileItem.preview` of [files] (key = `FileItem.id`).
  void importFromIndex(Iterable<FileItem> files) {
    Map<String, Uint8List>? fresh;
    for (final f in files) {
      final wire = f.preview;
      if (wire == null) continue;
      final existing = _hashes[f.id];
      final hash = PreviewCodec.fromWire(wire);
      if (hash == null) continue;
      if (existing != null && listEquals(existing, hash)) continue;
      (fresh ??= <String, Uint8List>{})[f.id] = hash;
    }
    if (fresh != null) _putAll(fresh);
  }

  void _putAll(Map<String, Uint8List> entries) {
    final records = BytesBuilder(copy: false);
    var any = false;
    entries.forEach((key, hash) {
      final keyBytes = utf8.encode(key);
      if (keyBytes.isEmpty ||
          keyBytes.length > 255 ||
          hash.isEmpty ||
          hash.length > 255 ||
          !isValidThumbHash(hash)) {
        return;
      }
      final old = _hashes[key];
      if (old != null && listEquals(old, hash)) return;
      if (old != null) _liveBytes -= 1 + keyBytes.length + 1 + old.length;
      final copy = Uint8List.fromList(hash);
      _hashes[key] = copy;
      _average.remove(key);
      _liveBytes += 1 + keyBytes.length + 1 + copy.length;
      records
        ..addByte(keyBytes.length)
        ..add(keyBytes)
        ..addByte(copy.length)
        ..add(copy);
      any = true;
    });
    if (any) {
      _bump();
      _enqueueAppend(records.takeBytes());
    }
  }

  final BytesBuilder _pending = BytesBuilder(copy: false);
  bool _flushQueued = false;

  /// Appends are coalesced: records added while a write is queued or running
  /// go out together in the next single write.
  void _enqueueAppend(Uint8List data) {
    _pending.add(data);
    if (_flushQueued) return;
    _flushQueued = true;
    _io = _io.then((_) async {
      _flushQueued = false;
      final batch = _pending.takeBytes();
      if (batch.isEmpty) return;
      await init();
      final file = _file;
      if (file == null) return;
      await file.writeAsBytes(batch, mode: FileMode.append);
      _fileBytes += batch.length;
      if (_fileBytes > 2 * _liveBytes && _fileBytes - _liveBytes > _minDeadBytes) {
        await _compact(file);
      }
    }).catchError((Object _) {});
  }

  Future<void> _compact(File file) async {
    final out = BytesBuilder(copy: false);
    _hashes.forEach((key, hash) {
      final k = utf8.encode(key);
      out
        ..addByte(k.length)
        ..add(k)
        ..addByte(hash.length)
        ..add(hash);
    });
    final bytes = out.takeBytes();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    _fileBytes = bytes.length;
  }

  /// Completes when every queued write has finished (tests).
  @visibleForTesting
  Future<void> flushForTesting() => _io;

  /// Bytes currently in the backing file (tests).
  @visibleForTesting
  int get fileBytesForTesting => _fileBytes;

  /// Drops in-memory state so [init] can reload from the file (tests).
  @visibleForTesting
  void resetForTesting() {
    _hashes.clear();
    _average.clear();
    _file = null;
    _init = null;
    _liveBytes = 0;
    _fileBytes = 0;
    _io = Future<void>.value();
    _flushQueued = false;
    _pending.clear();
  }
}
