import 'dart:io';
import 'package:photo_manager/photo_manager.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/device/device_library.dart';
import '../../../models/file_index.dart';
import '../../../models/file_item.dart';
import '../models/gallery_entry.dart';

/// Builds the unified Gallery timeline: every device photo/video merged with
/// every cloud [FileItem], deduplicated so a photo that's both on-device and
/// uploaded appears once (see [GalleryEntry]).
class GalleryFeedService {
  GalleryFeedService._();
  static final GalleryFeedService instance = GalleryFeedService._();

  List<GalleryEntry>? _previous;

  Future<List<GalleryEntry>> buildEntries(FileIndex index) async {
    if (!Platform.isAndroid) return _cloudOnly(index);

    // Idempotent — guards against this running before MainShell's
    // initRegistry() finishes, since Gallery (tab 0) is mounted eagerly by
    // the shell's IndexedStack.
    await BackupRegistry.instance.init();

    // Passive check only: never calls requestPermissionExtend() here, which
    // can pop Android 14's system photo picker. That's deliberately deferred
    // to an explicit user action (see gallery_screen.dart's permission
    // banner) — the same reason backup_provider.dart defers it to the Albums
    // tab instead of asking at app startup.
    final permission = await PhotoManager.getPermissionState(
      requestOption: const PermissionRequestOption(),
    );
    if (!permission.hasAccess) return _cloudOnly(index);

    // Paged and cached by DeviceLibrary: most deviceStateVersion bumps are
    // from uploading/downloading *existing* assets, which never change the
    // device's asset count, so they cost one count query, not a re-scan.
    final assets = await DeviceLibrary.instance.all();
    final next = mergeFeed(
      assets: assets,
      index: index,
      fileItemIdFor: BackupRegistry.instance.fileItemIdFor,
    );
    final previous = _previous;
    if (previous != null && sameFeed(previous, next)) return previous;
    return _previous = next;
  }

  /// Forces the next [buildEntries] call to re-scan the device instead of
  /// using the cached asset list (e.g. after a pull-to-refresh).
  void invalidateCache() => DeviceLibrary.instance.invalidate();

  // Re-sorted by the entries' own date: mediaFiles is ordered by upload
  // time, which is not the key the month sections group by.
  List<GalleryEntry> _cloudOnly(FileIndex index) => sortNewestFirst([
    for (final f in index.mediaFiles) GalleryEntry(fileItem: f),
  ]);
}

/// True when [a] and [b] show exactly the same entries in the same order, so
/// the previous list instance can be kept (downstream providers then see no
/// change at all).
bool sameFeed(List<GalleryEntry> a, List<GalleryEntry> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (!identical(x.fileItem, y.fileItem)) return false;
    final xa = x.asset, ya = y.asset;
    if (identical(xa, ya)) continue;
    if (xa == null ||
        ya == null ||
        xa.id != ya.id ||
        xa.modifiedDateSecond != ya.modifiedDateSecond) {
      return false;
    }
  }
  return true;
}

/// Pure merge of the device library with the cloud index. Same semantics the
/// feed always had: registry link first, then the unique-original-name
/// fallback, archived photos hidden everywhere, cloud-only entries from
/// non-archived image/video files. Sorted newest first by
/// [GalleryEntry.effectiveDateMs] (the capture date; see there), ties keeping
/// input order.
///
/// Works over precomputed int/string columns: the date is read once per
/// entry instead of building a DateTime per comparison.
List<GalleryEntry> mergeFeed({
  required List<AssetEntity> assets,
  required FileIndex index,
  required String? Function(String assetId) fileItemIdFor,
}) {
  final files = index.files;
  final cloudById = <String, FileItem>{for (final f in files) f.id: f};
  final consumed = <String>{};

  // After a reinstall the registry's asset->cloud links are gone, so every
  // photo that is both on the device and in the vault would show up twice
  // (and the cloud copy's tile would fetch its thumbnail over the network).
  // Fall back to the original file name, but only when it identifies one
  // single photo on each side — "IMG_20261031_213744.jpg" does, "image.jpg"
  // doesn't and is left alone rather than risking a wrong merge.
  final cloudByName = <String, List<FileItem>>{};
  for (final f in files) {
    (cloudByName[f.name] ??= []).add(f);
  }
  final deviceNameCount = <String, int>{};
  for (final a in assets) {
    final name = a.title;
    if (name != null) deviceNameCount[name] = (deviceNameCount[name] ?? 0) + 1;
  }

  final entries = <GalleryEntry>[];

  for (final asset in assets) {
    final fileItemId = fileItemIdFor(asset.id);
    var matched = fileItemId != null ? cloudById[fileItemId] : null;
    if (matched == null) {
      final name = asset.title;
      final candidates = name == null ? null : cloudByName[name];
      if (candidates != null &&
          candidates.length == 1 &&
          deviceNameCount[name] == 1 &&
          !consumed.contains(candidates.first.id)) {
        matched = candidates.first;
      }
    }
    if (matched != null) consumed.add(matched.id);
    // An archived-but-still-on-device photo hides everywhere in Gallery,
    // not just the cloud side of it — the cloud-only loop below already
    // skips archived files, so this loop (built from the device asset list)
    // has to check archived itself.
    if (matched?.archived == true) continue;
    entries.add(GalleryEntry(asset: asset, fileItem: matched));
  }
  for (final f in files) {
    if (f.archived || consumed.contains(f.id)) continue;
    if (!(f.mimeType.startsWith('image/') || f.mimeType.startsWith('video/'))) {
      continue;
    }
    entries.add(GalleryEntry(fileItem: f));
  }
  return sortNewestFirst(entries);
}

/// [entries] sorted newest first by [GalleryEntry.effectiveDateMs] — the same
/// key [groupEntriesByMonth] buckets by — ties keeping input order.
List<GalleryEntry> sortNewestFirst(List<GalleryEntry> entries) {
  final dates = [for (final e in entries) e.effectiveDateMs];
  // Dart's List.sort is not stable: sort indices with the position as the
  // tie-breaker so equal dates keep a deterministic order.
  final order = List<int>.generate(entries.length, (i) => i);
  order.sort((a, b) {
    final da = dates[a], db = dates[b];
    return da != db ? db.compareTo(da) : a.compareTo(b);
  });
  return [for (final i in order) entries[i]];
}
