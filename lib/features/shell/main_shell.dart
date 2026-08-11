import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/backup/background_execution_service.dart';
import '../albums/screens/albums_screen.dart';
import '../backup/providers/backup_provider.dart';
import '../explorer/providers/index_provider.dart';
import '../explorer/screens/explorer_screen.dart';
import '../gallery/screens/gallery_screen.dart';
import '../profile/providers/profile_provider.dart';
import 'scroll_to_top.dart';

/// Top-level navigation: Gallery (default), Albums, and Files. The vault index
/// is loaded once here and shared by all three tabs.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _index = 0;
  int _scrollTopSeq = 0;

  /// Tapping a nav destination scrolls that tab's list back to the top —
  /// including (especially) the tab already selected, which otherwise did
  /// nothing at all and left you scrolling by hand from deep in the timeline.
  void _onDestinationSelected(int i) {
    setState(() => _index = i);
    ref.read(scrollToTopProvider.notifier).state =
        ScrollToTopSignal(i, ++_scrollTopSeq);
  }

  /// Debug/verification hook: with --dart-define=TV_AUTO_UPLOAD=1 the app
  /// pushes every pending device photo/video into the transfer queue once
  /// after startup. Not wired to any UI; normal builds leave it off.
  static const _autoUpload = String.fromEnvironment('TV_AUTO_UPLOAD') == '1';

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
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onDestinationSelected,
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
