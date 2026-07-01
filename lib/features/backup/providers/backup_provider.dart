import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/backup_service.dart';
import '../../explorer/providers/index_provider.dart';

class BackupState {
  /// All device albums visible on this device (Android only).
  final List<AssetPathEntity> deviceAlbums;

  /// Albums currently enabled for backup (by device album id).
  final Set<String> enabledIds;

  /// Progress for the currently running sync, keyed by album id.
  final Map<String, BackupProgress> progress;

  /// Whether device albums have been loaded yet.
  final bool loaded;

  const BackupState({
    this.deviceAlbums = const [],
    this.enabledIds = const {},
    this.progress = const {},
    this.loaded = false,
  });

  BackupState copyWith({
    List<AssetPathEntity>? deviceAlbums,
    Set<String>? enabledIds,
    Map<String, BackupProgress>? progress,
    bool? loaded,
  }) =>
      BackupState(
        deviceAlbums: deviceAlbums ?? this.deviceAlbums,
        enabledIds: enabledIds ?? this.enabledIds,
        progress: progress ?? this.progress,
        loaded: loaded ?? this.loaded,
      );

  bool isEnabled(String albumId) => enabledIds.contains(albumId);

  BackupProgress? progressFor(String albumId) => progress[albumId];
}

class BackupNotifier extends StateNotifier<BackupState> {
  BackupNotifier(this._ref) : super(const BackupState());

  final Ref _ref;

  /// Initialises only the SharedPreferences registry. Safe to call immediately
  /// after login — does NOT request photo permissions or open any system UI.
  Future<void> initRegistry() async {
    await BackupRegistry.instance.init();
    final enabled = BackupRegistry.instance.enabledAlbumIds.toSet();
    state = state.copyWith(enabledIds: enabled);
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
    // Sync any albums that had backup enabled in a previous session.
    syncAll();
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

  /// Runs a backup sync for [album], updating progress state as it goes.
  Future<void> syncAlbum(AssetPathEntity album) async {
    await BackupService.instance.syncAlbum(
      album,
      (p) => state = state.copyWith(progress: {...state.progress, album.id: p}),
      (item) => _ref.read(indexProvider.notifier).addFile(item),
    );
    // Clear progress after completion.
    final updated = Map<String, BackupProgress>.from(state.progress)
      ..remove(album.id);
    state = state.copyWith(progress: updated);
  }

  /// Runs sync for all albums that currently have backup enabled.
  Future<void> syncAll() async {
    for (final album in state.deviceAlbums) {
      if (state.isEnabled(album.id)) await syncAlbum(album);
    }
  }
}

final backupProvider =
    StateNotifierProvider<BackupNotifier, BackupState>((ref) => BackupNotifier(ref));
