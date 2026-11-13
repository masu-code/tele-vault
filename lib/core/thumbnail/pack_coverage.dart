import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tv_core/models.dart' show ThumbPackRef;

import 'pack_installer.dart' show PackTocResult;
import 'thumb_store.dart';

/// Which thumbnail ids each pack in the index holds, cached on this device in
/// `<thumbDir>/_packs_covered.json`:
/// `{"v":1,"packs":{"<message_id>":{"id":"<pack_id>","ids":["<id>",...]}}}`.
///
/// The index only points at packs (`ThumbPackRef` has no ids), so a pack made
/// elsewhere is read once per device through its TOC (header + TOC, a ranged
/// read, never the thumbnails); a pack made here is recorded the moment it is
/// created. Merged on write, never replaced wholesale.
class PackCoverage {
  PackCoverage(this._store);

  static const String fileName = '_packs_covered.json';

  final ThumbStore _store;
  Future<void> _io = Future<void>.value();

  Future<File> _file() async => File(p.join(await _store.dirPath(), fileName));

  /// message id -> (pack id, ids). Empty when missing or unreadable (the TOCs
  /// are then read again: idempotent).
  Future<Map<int, ({String packId, List<String> ids})>> load() async {
    final out = <int, ({String packId, List<String> ids})>{};
    try {
      final file = await _file();
      if (!await file.exists()) return out;
      final doc = jsonDecode(await file.readAsString());
      if (doc is! Map || doc['v'] != 1 || doc['packs'] is! Map) return out;
      (doc['packs'] as Map).forEach((k, v) {
        final m = k is String ? int.tryParse(k) : null;
        if (m == null || v is! Map) return;
        final id = v['id'];
        final ids = v['ids'];
        if (id is! String || ids is! List) return;
        out[m] = (packId: id, ids: [for (final x in ids) if (x is String) x]);
      });
    } catch (_) {
      // Unreadable: start over.
    }
    return out;
  }

  /// Records that pack [packId] in message [messageId] holds [ids]. Never
  /// throws: a lost record only means one more TOC read later.
  Future<void> record(int messageId, String packId, List<String> ids) {
    final next = _io.then((_) async {
      final all = await load();
      all[messageId] = (packId: packId, ids: List<String>.of(ids));
      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'v': 1,
          'packs': {
            for (final e in all.entries) '${e.key}': {'id': e.value.packId, 'ids': e.value.ids},
          },
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    }).catchError((Object _) {});
    _io = next;
    return next;
  }

  /// Every id held by [refs], reading (and caching) the TOC of each pack the
  /// cache does not know yet. Refs in [known] are skipped (their ids are
  /// already accounted for by the caller). Returns null when any TOC could
  /// not be read for a retryable reason: coverage is then unknown and the
  /// caller must not pack anything. A pack that can never be read (not a
  /// pack, message gone) covers nothing: no device can install it either.
  Future<Set<String>?> coveredBy(
    List<ThumbPackRef> refs, {
    required Future<PackTocResult> Function(int messageId) readToc,
    Set<int> known = const {},
  }) async {
    final cache = await load();
    final out = <String>{};
    for (final ref in refs) {
      if (known.contains(ref.messageId)) continue;
      final hit = cache[ref.messageId];
      if (hit != null && hit.packId == ref.id) {
        out.addAll(hit.ids);
        continue;
      }
      final PackTocResult toc;
      try {
        toc = await readToc(ref.messageId);
      } catch (_) {
        return null;
      }
      if (!toc.ok) {
        if (!toc.permanent) return null;
        await record(ref.messageId, ref.id, const []);
        continue;
      }
      await record(ref.messageId, ref.id, toc.ids);
      out.addAll(toc.ids);
    }
    return out;
  }
}
