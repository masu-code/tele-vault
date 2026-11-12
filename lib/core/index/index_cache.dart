import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tv_core/codecs.dart' show crc32;

import '../../models/file_index.dart';

/// The index as last stored remotely, read back from the device.
class CachedIndex {
  final FileIndex index;

  /// The exact bytes stored remotely (kept for backups before the next write).
  final Uint8List bytes;
  final int messageId;

  /// Null for a legacy text-message index.
  final int? documentId;
  final bool legacy;

  /// `AuthorizationKey.id` of the session that wrote the cache, if known.
  final int? account;

  const CachedIndex({
    required this.index,
    required this.bytes,
    required this.messageId,
    required this.documentId,
    required this.legacy,
    required this.account,
  });
}

/// Local copy of the vault index plus its write backups, all under
/// `<appSupport>`:
///
/// - `index_cache.json`: the index bytes exactly as stored remotely;
/// - `index_cache.meta`: `{"message_id","document_id","saved_at","size",
///   "crc32","legacy","account"}`. `size` + `crc32` tie the meta to the bytes:
///   the app and the headless engine both write these two files, and a pair
///   that does not match (one writer's bytes, the other's meta) is rejected
///   instead of being trusted as "remote document X";
/// - `index_backups/<utc>-<tag>.json`: what was stored remotely before each
///   write (and `<utc>-<tag>-unsaved.json`: the bytes of a write that
///   failed), newest [keepBackups] kept.
///
/// Every file is written to a temp name and renamed into place, so a reader
/// (or a crash) never sees a torn file. Reads, CRC and JSON decoding run in
/// `Isolate.run`, off the UI isolate.
class IndexCache {
  IndexCache({Future<Directory> Function()? resolveDir})
      : _resolveDir = resolveDir ?? getApplicationSupportDirectory;

  /// Cache rooted at [dir] (tests).
  @visibleForTesting
  IndexCache.inDirectory(Directory dir) : _resolveDir = (() async => dir);

  static const int keepBackups = 20;
  static const String cacheName = 'index_cache.json';
  static const String metaName = 'index_cache.meta';
  static const String backupDirName = 'index_backups';

  final Future<Directory> Function() _resolveDir;
  final Random _random = Random();

  Future<String> _root() async => (await _resolveDir()).path;

  /// The cached index, or null when there is none or it does not verify.
  /// Never throws.
  Future<CachedIndex?> read() async {
    try {
      final root = await _root();
      return await Isolate.run(() => _readSync(root));
    } catch (_) {
      return null;
    }
  }

  /// Replaces the cache with [bytes] (the index as now stored remotely).
  /// Throws on failure; callers treat a failed cache write as non-fatal.
  Future<void> write(
    Uint8List bytes, {
    required int messageId,
    required int? documentId,
    bool legacy = false,
    int? account,
  }) async {
    final root = await _root();
    final suffix = _tmpSuffix();
    final savedAt = DateTime.now().toUtc().toIso8601String();
    await Isolate.run(() => _writeSync(
          root,
          bytes,
          suffix,
          <String, dynamic>{
            'message_id': messageId,
            'document_id': documentId,
            'saved_at': savedAt,
            'size': bytes.length,
            'crc32': crc32(bytes),
            'legacy': legacy,
            'account': account,
          },
        ));
  }

  /// Writes [bytes] to `index_backups/<utc>[-label].json` and prunes old
  /// backups. Throws when the backup could not be written: the caller must
  /// not overwrite the remote index without it.
  Future<File> backup(Uint8List bytes, {String? label}) async {
    final root = await _root();
    final dir = Directory(p.join(root, backupDirName));
    await dir.create(recursive: true);
    final stamp = _stamp(DateTime.now().toUtc());
    // Random tag: two backups in the same millisecond (a conflict retry) must
    // not overwrite each other.
    final tag = _random.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    final name = label == null ? '$stamp-$tag.json' : '$stamp-$tag-$label.json';
    final file = File(p.join(dir.path, name));
    final tmp = File('${file.path}.${_tmpSuffix()}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    final check = await file.length();
    if (check != bytes.length) {
      throw FileSystemException('Index backup is incomplete', file.path);
    }
    await _prune(dir);
    return file;
  }

  /// Backups currently on disk, oldest first (tests, diagnostics).
  Future<List<File>> listBackups() async {
    try {
      final dir = Directory(p.join(await _root(), backupDirName));
      if (!await dir.exists()) return const [];
      final files = await dir.list().where((e) => e is File && e.path.endsWith('.json')).cast<File>().toList();
      files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      return files;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _prune(Directory dir) async {
    final files = await listBackups();
    final excess = files.length - keepBackups;
    for (var i = 0; i < excess; i++) {
      try {
        await files[i].delete();
      } catch (_) {
        // Another writer (headless engine) pruned it first.
      }
    }
    // Temp files left by a killed writer.
    try {
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.tmp')) {
          final age = DateTime.now().difference(await e.lastModified());
          if (age > const Duration(hours: 1)) await e.delete();
        }
      }
    } catch (_) {}
  }

  String _tmpSuffix() =>
      '${DateTime.now().microsecondsSinceEpoch}${_random.nextInt(1 << 30)}';

  /// `20261111T093015123Z`: sortable by name.
  static String _stamp(DateTime utc) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}T'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}'
        '${utc.millisecond.toString().padLeft(3, '0')}Z';
  }
}

CachedIndex? _readSync(String root) {
  final cacheFile = File(p.join(root, IndexCache.cacheName));
  final metaFile = File(p.join(root, IndexCache.metaName));
  if (!cacheFile.existsSync() || !metaFile.existsSync()) return null;
  final meta = jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
  final bytes = cacheFile.readAsBytesSync();
  if (meta['size'] != bytes.length || meta['crc32'] != crc32(bytes)) return null;
  final messageId = meta['message_id'] as int?;
  if (messageId == null) return null;
  final legacy = meta['legacy'] == true;
  final documentId = meta['document_id'] as int?;
  if (!legacy && documentId == null) return null;
  return CachedIndex(
    index: FileIndex.decode(utf8.decode(bytes)),
    bytes: bytes,
    messageId: messageId,
    documentId: documentId,
    legacy: legacy,
    account: meta['account'] as int?,
  );
}

void _writeSync(String root, Uint8List bytes, String suffix, Map<String, dynamic> meta) {
  Directory(root).createSync(recursive: true);
  final cachePath = p.join(root, IndexCache.cacheName);
  final metaPath = p.join(root, IndexCache.metaName);
  final cacheTmp = File('$cachePath.$suffix.tmp');
  cacheTmp.writeAsBytesSync(bytes, flush: true);
  cacheTmp.renameSync(cachePath);
  final metaTmp = File('$metaPath.$suffix.tmp');
  metaTmp.writeAsStringSync(jsonEncode(meta), flush: true);
  metaTmp.renameSync(metaPath);
}
