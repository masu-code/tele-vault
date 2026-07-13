import 'dart:io';
import 'package:photo_manager/photo_manager.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../models/file_index.dart';
import '../models/gallery_entry.dart';

/// Builds the unified Gallery timeline: every device photo/video merged with
/// every cloud [FileItem], deduplicated so a photo that's both on-device and
/// uploaded appears once (see [GalleryEntry]).
class GalleryFeedService {
  GalleryFeedService._();
  static final GalleryFeedService instance = GalleryFeedService._();

  List<AssetEntity>? _cachedAssets;
  int? _cachedAssetCount;

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

    final paths = await PhotoManager.getAssetPathList(
      hasAll: true,
      onlyAll: true,
      type: RequestType.image | RequestType.video,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    if (paths.isEmpty) return _cloudOnly(index);

    final all = paths.first;
    final count = await all.assetCountAsync;
    List<AssetEntity> assets;
    if (_cachedAssets != null && _cachedAssetCount == count) {
      // The device's asset count is unchanged — most deviceStateVersion
      // bumps are from uploading/downloading *existing* assets, which never
      // changes this count, so skip the expensive full re-scan.
      assets = _cachedAssets!;
    } else {
      assets = await all.getAssetListRange(start: 0, end: count);
      _cachedAssets = assets;
      _cachedAssetCount = count;
    }
    return _merge(assets, index);
  }

  /// Forces the next [buildEntries] call to re-scan the device instead of
  /// using the cached asset list (e.g. after a pull-to-refresh).
  void invalidateCache() {
    _cachedAssets = null;
    _cachedAssetCount = null;
  }

  List<GalleryEntry> _cloudOnly(FileIndex index) =>
      index.mediaFiles.map((f) => GalleryEntry(fileItem: f)).toList();

  List<GalleryEntry> _merge(List<AssetEntity> assets, FileIndex index) {
    final registry = BackupRegistry.instance;
    final cloudById = {for (final f in index.files) f.id: f};
    final consumed = <String>{};
    final entries = <GalleryEntry>[];

    for (final asset in assets) {
      final fileItemId = registry.fileItemIdFor(asset.id);
      final matched = fileItemId != null ? cloudById[fileItemId] : null;
      if (matched != null) consumed.add(matched.id);
      entries.add(GalleryEntry(asset: asset, fileItem: matched));
    }
    for (final f in index.mediaFiles) {
      if (!consumed.contains(f.id)) entries.add(GalleryEntry(fileItem: f));
    }

    entries.sort((a, b) => b.effectiveDate.compareTo(a.effectiveDate));
    return entries;
  }
}
