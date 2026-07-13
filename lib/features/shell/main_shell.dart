import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../core/backup/background_execution_service.dart';
import '../../core/backup/backup_registry.dart';
import '../albums/screens/albums_screen.dart';
import '../backup/providers/backup_provider.dart';
import '../explorer/providers/index_provider.dart';
import '../explorer/screens/explorer_screen.dart';
import '../gallery/screens/gallery_screen.dart';
import '../profile/providers/profile_provider.dart';

/// Top-level navigation: Gallery (default), Albums, and Files. The vault index
/// is loaded once here and shared by all three tabs.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _index = 0;

  /// Debug/verification hook: with --dart-define=TV_AUTO_UPLOAD=1 the app
  /// pushes every pending device photo/video into the transfer queue once
  /// after startup. Not wired to any UI; normal builds leave it off.
  static const _autoUpload = String.fromEnvironment('TV_AUTO_UPLOAD') == '1';

  /// One-time cleanup hook: with --dart-define=TV_FIX_ORPHANS=1, clears the
  /// "uploaded" flag on any registry entry whose linked file isn't actually
  /// present in the just-loaded index — see [BackupRegistry.clearUploaded].
  /// Cheap (no network scan beyond the normal index load), safe to run once.
  static const _fixOrphans = String.fromEnvironment('TV_FIX_ORPHANS') == '1';

  static const _tabs = [GalleryScreen(), AlbumsScreen(), ExplorerScreen()];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(indexProvider.notifier).load();
      await ref.read(backupProvider.notifier).initRegistry();
      unawaited(ref.read(profileProvider.notifier).load());
      unawaited(BackgroundExecutionService.instance.init());
      // Requested together with the battery-optimization exemption above, on
      // first launch, so a fresh install can start backing up in the
      // background immediately without the user first having to open the
      // Albums tab. This brings back the exact thing an earlier fix deferred
      // (the Android 14 system photo picker can briefly cover the launch
      // screen) — accepted tradeoff, per explicit request. AlbumsScreen's own
      // call to loadDeviceAlbums() is idempotent (guarded by state.loaded),
      // so it's a no-op by the time the user gets there.
      unawaited(ref.read(backupProvider.notifier).loadDeviceAlbums());
      if (_autoUpload) {
        final n = await ref.read(backupProvider.notifier).uploadAllPending();
        debugPrint('TVQUEUE: auto-upload enqueued $n pending item(s)');
      }
      if (_fixOrphans) await _fixOrphanedRegistryLinks();
    });
  }

  Future<void> _fixOrphanedRegistryLinks() async {
    final registry = BackupRegistry.instance;
    final cloudIds = ref.read(indexProvider).index.files.map((f) => f.id).toSet();
    var cleared = 0;
    for (final assetId in registry.uploadedAssetIds) {
      final fileItemId = registry.fileItemIdFor(assetId);
      final isOrphan = fileItemId == null || !cloudIds.contains(fileItemId);
      if (!isOrphan) continue;

      String label = assetId;
      try {
        final asset = await AssetEntity.fromId(assetId);
        if (asset != null) {
          label = '${asset.title ?? assetId} (created ${asset.createDateTime})';
        }
      } catch (_) {}
      debugPrint('TVDIAG: orphan asset=$assetId title=$label '
          'fileItemId=${fileItemId ?? "none"} '
          'reason=${fileItemId == null ? "never linked to a file" : "linked file not found in any index snapshot"}');

      await registry.clearUploaded(assetId);
      cleared++;
    }
    debugPrint('TVDIAG: orphan cleanup done — cleared=$cleared '
        'remainingUploaded=${registry.uploadedAssetIds.length}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            selectedIcon: Icon(Icons.photo_library),
            label: 'Gallery',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_album_outlined),
            selectedIcon: Icon(Icons.photo_album),
            label: 'Albums',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Files',
          ),
        ],
      ),
    );
  }
}
