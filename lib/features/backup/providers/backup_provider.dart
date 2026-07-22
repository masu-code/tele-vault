import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/backup_service.dart';
import '../../transfer/providers/transfer_queue_provider.dart';

class BackupState {
  /// All device albums visible on this device (Android only).
  final List<AssetPathEntity> deviceAlbums;

  /// Albums currently enabled for backup (by device album id).
  final Set<String> enabledIds;

  /// Progress for the currently running sync, keyed by album id.
  final Map<String, BackupProgress> progress;

  /// Whether device albums have been loaded yet.
  final bool loaded;

  /// Bumped every time device albums are force-refreshed (e.g. after freeing
  /// up storage), so album cards know their cached cover/count is stale even
  /// though the album's own id didn't change.
  final int refreshTick;

  /// Whether automatic backup is allowed to run over mobile data. Mirrors
  /// [BackupRegistry.allowMobileData]; kept in state so the settings toggle
  /// updates live.
  final bool allowMobileData;

  const BackupState({
    this.deviceAlbums = const [],
    this.enabledIds = const {},
    this.progress = const {},
    this.loaded = false,
    this.refreshTick = 0,
    this.allowMobileData = false,
  });

  BackupState copyWith({
    List<AssetPathEntity>? deviceAlbums,
    Set<String>? enabledIds,
    Map<String, BackupProgress>? progress,
    bool? loaded,
    int? refreshTick,
    bool? allowMobileData,
  }) =>
      BackupState(
        deviceAlbums: deviceAlbums ?? this.deviceAlbums,
        enabledIds: enabledIds ?? this.enabledIds,
        progress: progress ?? this.progress,
        loaded: loaded ?? this.loaded,
        refreshTick: refreshTick ?? this.refreshTick,
        allowMobileData: allowMobileData ?? this.allowMobileData,
      );

  bool isEnabled(String albumId) => enabledIds.contains(albumId);

  BackupProgress? progressFor(String albumId) => progress[albumId];
}

class BackupNotifier extends StateNotifier<BackupState> {
  BackupNotifier(this._ref) : super(const BackupState());

  final Ref _ref;

  bool _watching = false;
  Timer? _debounce;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  void Function(MethodCall)? _changeCallback;

  /// Initialises only the SharedPreferences registry. Safe to call immediately
  /// after login — does NOT request photo permissions or open any system UI.
  Future<void> initRegistry() async {
    await BackupRegistry.instance.init();
    final enabled = BackupRegistry.instance.enabledAlbumIds.toSet();
    state = state.copyWith(
      enabledIds: enabled,
      allowMobileData: BackupRegistry.instance.allowMobileData,
    );
  }

  Future<void> setAllowMobileData(bool value) async {
    await BackupRegistry.instance.setAllowMobileData(value);
    state = state.copyWith(allowMobileData: value);
    if (value) syncAll(); // pick up anything that was held back on mobile data
  }

  /// True when automatic backup is allowed to run right now: always on
  /// WiFi/ethernet, on mobile data only if the user opted in. Doesn't apply
  /// to explicit user actions (Gallery's own "Upload" button, etc.) — only
  /// the automatic paths below ([syncAlbum]/[syncAll] and the device-change
  /// watcher).
  Future<bool> _hasUsableConnection() async {
    final results = await Connectivity().checkConnectivity();
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return true;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return BackupRegistry.instance.allowMobileData;
    }
    return false;
  }

  /// Starts watching for new device photos/videos (to auto-upload them into
  /// enabled albums as they arrive) and for connectivity coming back on WiFi
  /// (to retry anything held back while on mobile data). Idempotent — safe to
  /// call every time [loadDeviceAlbums] runs.
  void _startWatching() {
    if (_watching) return;
    _watching = true;

    _changeCallback = (_) {
      _debounce?.cancel();
      // Multiple assets can land in one burst (e.g. a batch WhatsApp save) —
      // wait for things to settle before re-scanning enabled albums instead
      // of firing a sync per individual change event.
      _debounce = Timer(const Duration(seconds: 3), syncAll);
    };
    PhotoManager.addChangeCallback(_changeCallback!);
    unawaited(PhotoManager.startChangeNotify());

    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet)) {
        syncAll();
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    final cb = _changeCallback;
    if (cb != null) PhotoManager.removeChangeCallback(cb);
    _connectivitySub?.cancel();
    super.dispose();
  }

  /// Requests photo permission and loads device albums. Call lazily when the
  /// user navigates to the Albums tab — avoids the Android 14 system photo
  /// picker blocking the entire app UI on first launch.
  Future<void> loadDeviceAlbums() async {
    if (!Platform.isAndroid || state.loaded) return;
    // Guards against a race with initRegistry(): if this runs before that
    // finished, enabledAlbumIds would hit a null SharedPreferences instance
    // and throw, permanently leaving state.loaded false (this method is only
    // called once, from initState) — device albums would never show again
    // until app restart. init() is idempotent, so this is always safe.
    await BackupRegistry.instance.init();
    final albums = await BackupService.deviceAlbums();
    final enabled = BackupRegistry.instance.enabledAlbumIds.toSet();
    state = state.copyWith(deviceAlbums: albums, enabledIds: enabled, loaded: true);
    _startWatching();
    // Sync any albums that had backup enabled in a previous session.
    syncAll();
  }

  /// Re-fetches device albums from photo_manager unconditionally (unlike
  /// [loadDeviceAlbums], which only runs once). Call after anything that
  /// changes what's on the device outside of backup itself — e.g. after
  /// freeing up storage — so covers/counts don't stay stale.
  Future<void> refreshDeviceAlbums() async {
    if (!Platform.isAndroid) return;
    final albums = await BackupService.deviceAlbums();
    state = state.copyWith(deviceAlbums: albums, refreshTick: state.refreshTick + 1);
  }

  /// Toggles backup on/off for [albumId]. When enabling, triggers a sync.
  Future<void> toggleBackup(AssetPathEntity album) async {
    final id = album.id;
    final nowEnabled = !state.isEnabled(id);
    await BackupRegistry.instance.setAlbumEnabled(id, enabled: nowEnabled);
    state = state.copyWith(
      enabledIds: {
        ...state.enabledIds.where((e) => e != id),
        if (nowEnabled) id,
      },
    );
    if (nowEnabled) await syncAlbum(album);
  }

  /// Runs a backup sync for [album] by handing its pending assets to the
  /// global transfer queue — the SAME queue driven by Gallery's bulk
  /// upload/`uploadAllPending`. This used to run through `BackupService`'s
  /// own independent upload loop, which (now that all uploads are correctly
  /// serialized through one connection, to prevent the session corruption
  /// this app hit in practice) meant an auto-triggered album sync could sit
  /// in front of a user-initiated bulk upload and block it behind a large
  /// video for a long time, with two uncoordinated "queues" fighting over
  /// the same single-file-at-a-time slot. One real queue avoids that.
  Future<void> syncAlbum(AssetPathEntity album) async {
    if (!await _hasUsableConnection()) return;
    final count = await album.assetCountAsync;
    if (count == 0) return;
    final assets = await album.getAssetListRange(start: 0, end: count);
    final registry = BackupRegistry.instance;
    final pending = assets.where((a) => !registry.isUploaded(a.id)).toList();
    if (pending.isNotEmpty) {
      debugPrint('TVWATCH: syncAlbum ${album.name} count=$count pending=${pending.length}');
    }
    if (pending.isEmpty) return;
    _ref.read(transferQueueProvider.notifier).enqueueUploads(pending);
  }

  /// Runs sync for all albums that currently have backup enabled.
  Future<void> syncAll() async {
    for (final album in state.deviceAlbums) {
      if (state.isEnabled(album.id)) await syncAlbum(album);
    }
  }

  /// Enqueues every device photo/video not yet uploaded into the global
  /// transfer queue (a one-time push of everything pending). Uses the "all"
  /// virtual album so it covers every folder — camera, WhatsApp, Takeout,
  /// etc. — in a single pass. Returns how many were enqueued.
  Future<int> uploadAllPending() async {
    if (!Platform.isAndroid) return 0;
    await BackupRegistry.instance.init();
    final permission = await PhotoManager.getPermissionState(
      requestOption: const PermissionRequestOption(),
    );
    if (!permission.hasAccess) return 0;

    final paths = await PhotoManager.getAssetPathList(
      hasAll: true,
      onlyAll: true,
      type: RequestType.image | RequestType.video,
      filterOption: FilterOptionGroup(
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    if (paths.isEmpty) return 0;

    final all = paths.first;
    final count = await all.assetCountAsync;
    if (count == 0) return 0;
    final assets = await all.getAssetListRange(start: 0, end: count);
    final registry = BackupRegistry.instance;
    final pending = assets.where((a) => !registry.isUploaded(a.id)).toList();
    if (pending.isEmpty) return 0;

    _ref.read(transferQueueProvider.notifier).enqueueUploads(pending);
    return pending.length;
  }
}

final backupProvider =
    StateNotifierProvider<BackupNotifier, BackupState>((ref) => BackupNotifier(ref));
