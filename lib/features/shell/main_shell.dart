import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/backup/background_execution_service.dart';
import '../../core/backup/backup_registry.dart';
import '../../core/backup/transfer_notifications.dart';
import '../transfer/providers/transfer_queue_provider.dart';
import '../albums/screens/albums_screen.dart';
import '../backup/providers/backup_provider.dart';
import '../explorer/providers/index_provider.dart';
import '../explorer/screens/explorer_screen.dart';
import '../gallery/screens/gallery_screen.dart';
import '../profile/providers/maintenance_provider.dart';
import '../profile/providers/profile_provider.dart';
import 'scroll_to_top.dart';

/// Top-level navigation: Gallery (default), Albums, and Files. The vault index
/// is loaded once here and shared by all three tabs.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with WidgetsBindingObserver {
  int _index = 0;
  int _scrollTopSeq = 0;

  /// Tapping a nav destination scrolls that tab's list back to the top —
  /// including (especially) the tab already selected, which otherwise did
  /// nothing at all and left you scrolling by hand from deep in the timeline.
  void _onDestinationSelected(int i) {
    setState(() {
      _index = i;
      _visited.add(i);
    });
    ref.read(scrollToTopProvider.notifier).state = ScrollToTopSignal(
      i,
      ++_scrollTopSeq,
    );
  }

  /// Debug/verification hook: with --dart-define=TV_AUTO_UPLOAD=1 the app
  /// pushes every pending device photo/video into the transfer queue once
  /// after startup. Not wired to any UI; normal builds leave it off.
  static const _autoUpload = String.fromEnvironment('TV_AUTO_UPLOAD') == '1';

  static const _tabs = [GalleryScreen(), AlbumsScreen(), ExplorerScreen()];

  /// Tabs built so far. Albums and Files are only built after their first
  /// selection (so an index change doesn't rebuild three screens while two
  /// are never opened); once built they stay alive in the IndexedStack.
  final Set<int> _visited = {0};

  /// Coalesces the transfer-notification updates to at most one per second
  /// (the queue emits on every progress tick). The first update goes out
  /// immediately; later ones are held and only the latest is sent when the
  /// timer fires. "Not active" always cancels at once.
  static const _notifInterval = Duration(seconds: 1);
  Timer? _notifTimer;
  TransferState? _pendingNotif;

  void _scheduleNotification(TransferState s) {
    if (!s.active) {
      _notifTimer?.cancel();
      _notifTimer = null;
      _pendingNotif = null;
      _syncNotification(s);
      return;
    }
    if (_notifTimer == null) {
      _syncNotification(s);
      _notifTimer = Timer(_notifInterval, _flushNotification);
    } else {
      _pendingNotif = s;
    }
  }

  void _flushNotification() {
    final s = _pendingNotif;
    _pendingNotif = null;
    if (s == null) {
      _notifTimer = null;
      return;
    }
    _syncNotification(s);
    _notifTimer = Timer(_notifInterval, _flushNotification);
  }

  /// Tells the headless WorkManager task this process is alive and owns
  /// uploads (see [BackupRegistry.markAppAlive]); must stay well under the
  /// 60s freshness window [BackupRegistry.appRecentlyAlive] checks.
  Timer? _aliveTimer;
  static const _aliveInterval = Duration(seconds: 20);

  void _markAlive() {
    final registry = BackupRegistry.instance;
    unawaited(registry.init().then((_) => registry.markAppAlive()).catchError((Object e) {
      debugPrint('MainShell: alive heartbeat failed: $e');
    }));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _markAlive();
    _aliveTimer = Timer.periodic(_aliveInterval, (_) => _markAlive());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(indexProvider.notifier).load();
      // Automatic maintenance (thumbnail packs, capture dates) once synced.
      ref.read(autoMaintenanceBindingProvider);
      await ref.read(backupProvider.notifier).initRegistry();

      // These next two BOTH put system UI in front of the app on a fresh
      // install: the battery-optimization exemption opens a system settings
      // screen, and loading device albums requests the photo permission.
      // Fired together (as two back-to-back `unawaited`s, which is what this
      // used to be) they cancelled each other out — the settings Activity
      // took the foreground and Android dismissed the pending permission
      // request along with it, so the prompt never appeared, device albums
      // silently stayed empty, and nothing ever asked again (loadDeviceAlbums
      // is once-only, guarded by state.loaded). Awaiting the first before
      // starting the second is what makes both actually reach the user.
      await BackgroundExecutionService.instance.init();
      // Android 13+ shows no notification (including the progress bar below)
      // until this is granted. Sequential with the other system prompts for the
      // same reason as above.
      await TransferNotifications.instance.requestPermission();
      await ref.read(backupProvider.notifier).loadDeviceAlbums();

      // Last, once no system screen is covering us: MIUI cuts an app's
      // network the moment it isn't foreground, so a profile fetch started
      // while the battery-settings screen was up would fail and leave
      // "Could not load account" on screen. didChangeAppLifecycleState
      // retries it on resume if it still failed.
      unawaited(ref.read(profileProvider.notifier).load());

      if (_autoUpload) {
        final n = await ref.read(backupProvider.notifier).uploadAllPending();
        debugPrint('TVQUEUE: auto-upload enqueued $n pending item(s)');
      }
    });
  }

  @override
  void dispose() {
    _aliveTimer?.cancel();
    _notifTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Coming back from anywhere the OS put in front of us (the battery
    // settings screen, a permission dialog, the recents switcher) is exactly
    // when a fetch that failed for lack of network can succeed. load() is a
    // no-op once a profile is cached, so this only ever retries real
    // failures.
    unawaited(ref.read(profileProvider.notifier).load());
  }

  /// Mirrors the transfer queue into the system notification's progress bar.
  void _syncNotification(TransferState s) {
    final notifications = TransferNotifications.instance;
    if (!s.active) {
      unawaited(notifications.cancel());
      return;
    }
    final verb = s.kind == TransferKind.upload ? 'Uploading' : 'Downloading';
    // The file in flight, 1-based ("Uploading 1/5" while the first one goes
    // up, like the headless task's "Backing up n/total") — [done] alone read
    // "Uploading 0/5" for the whole first file.
    final position = s.total <= 0 ? 0 : (s.done + 1).clamp(1, s.total);
    // The bar tracks the file in flight, not the whole batch: with one 700 MB
    // video first in a batch of 26, a whole-batch bar sat at 2% for half an
    // hour and looked frozen. The batch position is in the title instead.
    final percent = (s.currentProgress * 100).round();
    final name = s.currentName ?? 'Working…';
    unawaited(notifications.showProgress(
      title: s.canceling ? 'Finishing…' : '$verb $position of ${s.total}',
      body: s.failed > 0
          ? '$name · $percent% · ${s.failed} failed'
          : '$name · $percent%',
      done: 0,
      total: 1,
      current: s.currentProgress,
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Only the fields the notification shows; the whole TransferState also
    // carries per-file data the shell doesn't need. Records compare by value.
    ref.listen(
      transferQueueProvider.select((s) => (
            active: s.active,
            kind: s.kind,
            total: s.total,
            done: s.done,
            failed: s.failed,
            name: s.currentName,
            progress: s.currentProgress,
            canceling: s.canceling,
          )),
      (_, _) => _scheduleNotification(ref.read(transferQueueProvider)),
    );
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < _tabs.length; i++)
            _visited.contains(i) ? _tabs[i] : const SizedBox.shrink(),
        ],
      ),
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
