import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../backup/providers/backup_provider.dart';

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
    final ids = BackupRegistry.instance.uploadedAssetIds;
    final assets = await Future.wait(ids.map(AssetEntity.fromId));
    final found = assets.whereType<AssetEntity>().toList();
    if (!mounted) return;
    setState(() {
      _candidates = found;
      _limitedAccess = permission == PermissionState.limited;
      _toDelete
        ..clear()
        ..addAll(found.map((a) => a.id));
      _loading = false;
    });
  }

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
      final deleted = await PhotoManager.editor.deleteWithIds(_toDelete.toList());
      await PhotoManager.clearFileCache();
      // The device's albums (covers/counts) are now stale — an emptied album
      // would otherwise keep showing its old cover and hang loading forever.
      await ref.read(backupProvider.notifier).refreshDeviceAlbums();
      bumpDeviceState(ref);
      if (!mounted) return;
      final skipped = _toDelete.length - deleted.length;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(skipped > 0
            ? 'Liberados ${deleted.length} archivo(s); $skipped no se pudieron borrar'
            : 'Liberados ${deleted.length} archivo(s)'),
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
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nada para liberar todavía.\nSolo se pueden borrar archivos que ya '
                      'estén respaldados en Telegram y sigan en el dispositivo.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
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
            if (_thumb != null)
              Opacity(
                opacity: widget.marked ? 0.5 : 1,
                child: Image.memory(_thumb!, fit: BoxFit.cover),
              )
            else
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
