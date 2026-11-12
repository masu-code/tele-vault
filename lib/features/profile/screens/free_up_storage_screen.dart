import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../models/capture_date.dart';
import '../../../models/file_index.dart';
import '../../backup/providers/backup_provider.dart';
import '../../explorer/providers/index_provider.dart';

/// The device assets "Free up space" may offer and delete: marked uploaded in
/// the registry AND linked to a file id that [index] holds. The registry alone
/// is not enough (an upload whose index write failed, or a file another device
/// removed from the vault, would lose its only copy). When [synced] is false
/// the index was not read from Telegram this session and cannot vouch for
/// anything, so nothing is deletable.
List<String> deletableAssetIds({
  required Iterable<String> uploaded,
  required String? Function(String assetId) fileItemIdFor,
  required FileIndex index,
  required bool synced,
}) {
  if (!synced) return const [];
  final inVault = {for (final f in index.files) f.id};
  return [
    for (final id in uploaded)
      if (inVault.contains(fileItemIdFor(id))) id,
  ];
}

/// What [stampThenSelectForDelete] decided.
class FreeUpDeletePlan {
  const FreeUpDeletePlan({required this.assetIds, required this.undated});

  /// Assets safe to delete: linked to an item of the index the stamp save
  /// returned, and that item carries a stored capture date.
  final List<String> assetIds;

  /// Selected assets kept on the device because no believable capture date
  /// could be stored for their item (once deleted it would jump to its
  /// upload time in the Gallery).
  final int undated;
}

/// Before "Free up space" deletes device copies: stores each linked item's
/// device capture date as `taken_at` (only where the item has none), in ONE
/// [applyAndSave], so the cloud-only item keeps its place in the Gallery.
///
/// [selected] is first narrowed by [deletableAssetIds] against [index] (D1:
/// nothing when not [synced]). When the save throws the error propagates and
/// the caller must delete nothing. Otherwise the deletable list is recomputed
/// against the index the save RETURNED (an item another writer removed drops
/// out) and keeps only assets whose item is now dated; assets for which
/// [deviceCaptureMsFor] gives no believable date are excluded and counted in
/// [FreeUpDeletePlan.undated].
Future<FreeUpDeletePlan> stampThenSelectForDelete({
  required Iterable<String> selected,
  required String? Function(String assetId) fileItemIdFor,
  required int? Function(String assetId) deviceCaptureMsFor,
  required FileIndex index,
  required bool synced,
  required Future<FileIndex> Function(FileIndex Function(FileIndex current) mutate)
      applyAndSave,
}) async {
  final linked = deletableAssetIds(
    uploaded: selected,
    fileItemIdFor: fileItemIdFor,
    index: index,
    synced: synced,
  );
  if (linked.isEmpty) return const FreeUpDeletePlan(assetIds: [], undated: 0);

  final byId = {for (final f in index.files) f.id: f};
  final stamps = <String, int>{};
  for (final assetId in linked) {
    final itemId = fileItemIdFor(assetId)!;
    if (hasStoredTakenAt(byId[itemId]!)) continue;
    final ms = plausibleCaptureMs(deviceCaptureMsFor(assetId));
    if (ms != null) stamps[itemId] = ms;
  }
  // Throws when the save fails: nothing is deleted then.
  final written = stamps.isEmpty
      ? index
      : await applyAndSave((current) => stampTakenAt(current, stamps));

  final dated = {
    for (final f in written.files)
      if (hasStoredTakenAt(f)) f.id,
  };
  final ids = <String>[];
  var undated = 0;
  for (final assetId in deletableAssetIds(
    uploaded: linked,
    fileItemIdFor: fileItemIdFor,
    index: written,
    synced: synced,
  )) {
    if (dated.contains(fileItemIdFor(assetId))) {
      ids.add(assetId);
    } else {
      undated++;
    }
  }
  return FreeUpDeletePlan(assetIds: ids, undated: undated);
}

/// Lets the user delete local copies of photos/videos that are already
/// backed up to Telegram, to free up device storage. Shows every candidate
/// pre-selected for deletion; the user deselects any they want to keep, then
/// confirms or cancels. Deleting on Android 11+ shows the OS's own
/// confirmation dialog (photo_manager/MediaStore) on top of this.
class FreeUpStorageScreen extends ConsumerStatefulWidget {
  const FreeUpStorageScreen({super.key});

  @override
  ConsumerState<FreeUpStorageScreen> createState() => _FreeUpStorageScreenState();
}

class _FreeUpStorageScreenState extends ConsumerState<FreeUpStorageScreen> {
  bool _loading = true;
  bool _deleting = false;
  bool _limitedAccess = false;

  /// The vault index could not be read from Telegram: nothing is offered.
  bool _indexNotSynced = false;
  List<AssetEntity> _candidates = [];
  final Set<String> _toDelete = {};

  @override
  void initState() {
    super.initState();
    _loadCandidates();
  }

  Future<void> _loadCandidates() async {
    // Under Android 14's "Select photos" permission, MediaStore only exposes
    // the subset of assets the user picked — AssetEntity.fromId silently
    // returns null for an uploaded asset outside that subset, so this list
    // (and the space it claims it can free) can undercount without any
    // visible error. Surface it instead of pretending the count is complete.
    final permission = await PhotoManager.getPermissionState(
      requestOption: const PermissionRequestOption(),
    );
    final synced = await ref.read(indexProvider.notifier).ensureRemoteLoaded();
    if (!mounted) return;
    final ids = _deletable(BackupRegistry.instance.uploadedAssetIds, synced: synced);
    final assets = await Future.wait(ids.map(AssetEntity.fromId));
    final found = assets.whereType<AssetEntity>().toList();
    if (!mounted) return;
    setState(() {
      _candidates = found;
      _indexNotSynced = !synced;
      _limitedAccess = permission == PermissionState.limited;
      _toDelete
        ..clear()
        ..addAll(found.map((a) => a.id));
      _loading = false;
    });
  }

  /// [deletableAssetIds] against the current index state.
  List<String> _deletable(Iterable<String> uploaded, {required bool synced}) =>
      deletableAssetIds(
        uploaded: uploaded,
        fileItemIdFor: BackupRegistry.instance.fileItemIdFor,
        index: ref.read(indexProvider).index,
        synced: synced,
      );

  Future<void> _grantFullAccess() async {
    await PhotoManager.presentLimited();
    if (mounted) setState(() => _loading = true);
    await _loadCandidates();
  }

  void _toggle(String id) {
    setState(() {
      if (!_toDelete.remove(id)) _toDelete.add(id);
    });
  }

  Future<void> _confirm() async {
    if (_toDelete.isEmpty) return;
    setState(() => _deleting = true);
    try {
      // Checked again right before deleting: the index may have changed (or
      // lost its sync) since the list was built. The capture dates are stored
      // first; a failed save throws here and nothing is deleted.
      final notifier = ref.read(indexProvider.notifier);
      final assetsById = {for (final a in _candidates) a.id: a};
      final plan = await stampThenSelectForDelete(
        selected: _toDelete,
        fileItemIdFor: BackupRegistry.instance.fileItemIdFor,
        deviceCaptureMsFor: (id) {
          final asset = assetsById[id];
          return asset == null ? null : deviceCaptureMs(asset);
        },
        index: ref.read(indexProvider).index,
        synced: notifier.remoteSynced,
        applyAndSave: notifier.applyAndSave,
      );
      final ids = plan.assetIds;
      final deleted =
          ids.isEmpty ? const <String>[] : await PhotoManager.editor.deleteWithIds(ids);
      await PhotoManager.clearFileCache();
      // The device's albums (covers/counts) are now stale — an emptied album
      // would otherwise keep showing its old cover and hang loading forever.
      await ref.read(backupProvider.notifier).refreshDeviceAlbums();
      bumpDeviceState(ref);
      if (!mounted) return;
      final undated = plan.undated;
      final skipped = _toDelete.length - deleted.length - undated;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text([
          'Liberados ${deleted.length} archivo(s)',
          if (undated > 0) '$undated sin fecha conocida se conservaron',
          if (skipped > 0) '$skipped no se pudieron borrar',
        ].join('; ')),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo liberar memoria: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_loading ? 'Liberar memoria' : '${_toDelete.length} para borrar'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _candidates.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _indexNotSynced
                          ? 'No se pudo leer el índice del respaldo en Telegram.\n'
                              'Por seguridad no se ofrece borrar nada; inténtalo de '
                              'nuevo con conexión.'
                          : 'Nada para liberar todavía.\nSolo se pueden borrar archivos que ya '
                              'estén respaldados en Telegram y sigan en el dispositivo.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              : Column(
                  children: [
                    if (_limitedAccess)
                      Container(
                        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2410),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded,
                                color: Colors.amber, size: 20),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'TeleVault solo tiene acceso a fotos seleccionadas — puede '
                                'que falten archivos respaldados en esta lista.',
                                style: TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                            ),
                            TextButton(
                              onPressed: _grantFullAccess,
                              child: const Text('Ampliar acceso'),
                            ),
                          ],
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Text(
                        'Todo está seleccionado para borrar por defecto. Toca lo que quieras conservar.',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ),
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(2),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 120,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                        ),
                        itemCount: _candidates.length,
                        itemBuilder: (context, i) {
                          final asset = _candidates[i];
                          return _CandidateTile(
                            key: ValueKey(asset.id),
                            asset: asset,
                            marked: _toDelete.contains(asset.id),
                            onTap: () => _toggle(asset.id),
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _deleting ? null : () => Navigator.pop(context),
                                child: const Text('Cancelar'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                onPressed: _deleting || _toDelete.isEmpty ? null : _confirm,
                                child: _deleting
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2, color: Colors.white),
                                      )
                                    : Text('Confirmar (${_toDelete.length})'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _CandidateTile extends StatefulWidget {
  const _CandidateTile({
    super.key,
    required this.asset,
    required this.marked,
    required this.onTap,
  });

  final AssetEntity asset;
  final bool marked;
  final VoidCallback onTap;

  @override
  State<_CandidateTile> createState() => _CandidateTileState();
}

class _CandidateTileState extends State<_CandidateTile> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_CandidateTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      setState(() => _thumb = null);
      _load();
    }
  }

  void _load() {
    widget.asset.thumbnailDataWithSize(const ThumbnailSize(200, 200)).then((data) {
      if (mounted && data != null) setState(() => _thumb = data);
    }).catchError((Object _) {
      // The asset may have just been deleted from the device.
    });
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.asset.type == AssetType.video;
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        color: const Color(0xFF1C1C1E),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_thumb != null) ...[
              Image.memory(_thumb!, fit: BoxFit.cover, gaplessPlayback: true),
              // Translucent overlay instead of an Opacity widget (which
              // forces a saveLayer per tile). Same look: the image blended
              // 50% into the tile background.
              if (widget.marked) const ColoredBox(color: Color(0x801C1C1E)),
            ] else
              Center(
                child: Icon(
                  isVideo ? Icons.movie_outlined : Icons.image_outlined,
                  color: Colors.white30,
                ),
              ),
            if (isVideo)
              const Align(
                child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 28),
              ),
            Positioned(
              top: 4,
              right: 4,
              child: Icon(
                widget.marked ? Icons.delete : Icons.check_circle,
                color: widget.marked ? Colors.redAccent : const Color(0xFF2AABEE),
                size: 20,
                shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
