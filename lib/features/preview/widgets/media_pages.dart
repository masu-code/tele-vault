import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/backup/asset_upload_service.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../core/download/download_service.dart';
import '../../../core/format_utils.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../../models/file_item.dart';
import '../../backup/providers/backup_provider.dart';
import '../../download/providers/download_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../video_controls.dart';
import 'add_to_album_sheet.dart';
import 'delete_source_dialog.dart';
import 'viewer_page_chrome.dart';

/// The page widgets and their action/info builders for both viewer kinds
/// (cloud [FileItem] and local device [AssetEntity]) — kept together, rather
/// than split back into their two screen files, because they're tightly
/// coupled (each page widget calls its matching *MediaActions/*MediaInfo
/// helper directly) and a mixed-type viewer (`MixedMediaViewerScreen`) needs
/// to reuse all four page widgets unchanged.

/// Lets a PageView be dragged with a mouse (desktop), not just touch. Shared
/// by every full-screen viewer screen.
class DragScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

// ---------------------------------------------------------------------------
// Cloud pages — a FileItem stored in the Telegram-backed vault.
// ---------------------------------------------------------------------------

class CloudImagePage extends ConsumerStatefulWidget {
  const CloudImagePage({super.key, required this.file});
  final FileItem file;

  @override
  ConsumerState<CloudImagePage> createState() => _CloudImagePageState();
}

class _CloudImagePageState extends ConsumerState<CloudImagePage> {
  double _progress = 0;
  File? _local;
  String? _error;

  final TransformationController _transform = TransformationController();
  // InteractiveViewer's own pan/scale recognizer competes with
  // ViewerPageChrome's vertical-drag recognizer for the same pointer once
  // zoomed in — without this, dragging to pan a zoomed photo can instead
  // (or also) drag the info panel open/closed, since both are trying to
  // interpret the same one-finger drag.
  final ValueNotifier<bool> _zoomed = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _transform.addListener(() {
      final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
      if (zoomed != _zoomed.value) _zoomed.value = zoomed;
    });
    DownloadService.instance.downloadToCache(
      widget.file,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    ).then((f) {
      if (mounted) setState(() => _local = f);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e.toString());
    });
  }

  @override
  void dispose() {
    _transform.dispose();
    _zoomed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)));
    }
    if (_local == null) {
      return Center(
        child: CircularProgressIndicator(value: _progress == 0 ? null : _progress),
      );
    }
    return ViewerPageChrome(
      actions: cloudMediaActions(context, ref, widget.file),
      infoBuilder: (context) => cloudMediaInfo(widget.file),
      gestureDisabled: _zoomed,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: Image.file(
            _local!,
            errorBuilder: (_, _, _) =>
                const Text('Could not display image.', style: TextStyle(color: Colors.white70)),
          ),
        ),
      ),
    );
  }
}

class CloudVideoPage extends ConsumerStatefulWidget {
  const CloudVideoPage({super.key, required this.file});
  final FileItem file;

  @override
  ConsumerState<CloudVideoPage> createState() => _CloudVideoPageState();
}

class _CloudVideoPageState extends ConsumerState<CloudVideoPage> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  double _progress = 0;
  bool _ready = false;
  String? _error;

  final TransformationController _transform = TransformationController();
  // See _CloudImagePageState for why this exists.
  final ValueNotifier<bool> _zoomed = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _transform.addListener(() {
      final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
      if (zoomed != _zoomed.value) _zoomed.value = zoomed;
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await DownloadService.instance.downloadToCache(
        widget.file,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      await _player.open(Media(file.path));
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _player.dispose();
    _transform.dispose();
    _zoomed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)));
    }
    if (!_ready) {
      return Center(
        child: CircularProgressIndicator(value: _progress == 0 ? null : _progress),
      );
    }
    return ViewerPageChrome(
      actions: cloudMediaActions(context, ref, widget.file),
      infoBuilder: (context) => cloudMediaInfo(widget.file),
      gestureDisabled: _zoomed,
      child: InteractiveViewer(
        transformationController: _transform,
        // Panning stays off for video: a single-finger drag needs to reach
        // the seek bar/tap-to-toggle-controls underneath undisturbed. Pinch
        // (scaleEnabled) still zooms in/out around the center.
        panEnabled: false,
        minScale: 1,
        maxScale: 5,
        child: Video(controller: _controller, controls: videoControlsWithSafeInsets),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared actions/info for a cloud FileItem — used by the viewer chrome above
// and by multi-select action bars (Gallery, Albums, Files).
// ---------------------------------------------------------------------------

/// Shares one or more cloud files, downloading to cache first as needed
/// (already-cached or backup-linked files share instantly).
Future<void> shareCloudFiles(BuildContext context, List<FileItem> files) async {
  try {
    final locals = await Future.wait(files.map(DownloadService.instance.downloadToCache));
    await SharePlus.instance.share(ShareParams(files: locals.map((f) => XFile(f.path)).toList()));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share: $e')));
    }
  }
}

List<ViewerAction> cloudMediaActions(BuildContext context, WidgetRef ref, FileItem file) {
  final saved = ref.watch(_savedProvider(file)).valueOrNull ?? false;
  // The Download action below never surfaced saveToDevice failures — the
  // notifier records them as DownloadState.error rather than throwing, so
  // without this listener a failed save just silently did nothing.
  ref.listen(downloadProvider, (prev, next) {
    if (next.error != null && next.error != prev?.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: ${next.error}')),
      );
    }
  });
  return [
    ViewerAction(
      icon: Icons.share_outlined,
      label: 'Share',
      onTap: () => shareCloudFiles(context, [file]),
    ),
    // Cloud-backup status: always uploaded here — informational.
    const ViewerAction(
      icon: Icons.cloud_done_outlined,
      label: 'Uploaded',
      onTap: null,
    ),
    // Device-presence status: Download (pending) or On device (done).
    ViewerAction(
      icon: saved ? Icons.smartphone : Icons.download_outlined,
      label: saved ? 'On device' : 'Download',
      onTap: saved
          ? null
          : () async {
              await ref.read(downloadProvider.notifier).saveToDevice(file);
              bumpDeviceState(ref);
            },
    ),
    ViewerAction(
      icon: Icons.playlist_add,
      label: 'Add to album',
      onTap: () => addFileIdsToAlbum(context, ref, [file.id]),
    ),
    ViewerAction(
      icon: Icons.delete_outline,
      label: 'Delete',
      color: Colors.redAccent,
      onTap: () => _deleteFile(context, ref, file),
    ),
  ];
}

final _savedProvider = FutureProvider.family.autoDispose<bool, FileItem>((ref, file) {
  ref.watch(deviceStateVersion);
  return LocalFileService.instance.isSaved(file);
});

Future<void> _deleteFile(BuildContext context, WidgetRef ref, FileItem file) async {
  final registry = BackupRegistry.instance;
  // Same lookup the "On device" action row icon uses — a raw
  // BackupRegistry.localPathFor() check alone misses files saved via the
  // explicit "Save to device" download (a plain Downloads-folder copy, not a
  // backup link), which showed the icon as on-device while this dialog
  // still only offered "delete from Telegram".
  final match = await LocalFileService.instance.existingLocalFile(file);
  if (!context.mounted) return;

  final source = await askDeleteSource(
    context,
    existsOnDevice: match != null,
    existsInCloud: true,
  );
  if (source == null || !context.mounted) return;

  if (source == DeleteSource.cloud || source == DeleteSource.both) {
    await ref.read(indexProvider.notifier).deleteFiles([file]);
    // deleteFiles doesn't rethrow on failure (it records mutationError and
    // keeps the item in the index) — closing the viewer here would make a
    // failed Telegram delete look like it succeeded.
    if (ref.read(indexProvider).mutationError != null) return;
  }
  if ((source == DeleteSource.device || source == DeleteSource.both) && match != null) {
    if (match.isLinkedAsset) {
      final assetId = registry.assetIdForFileItem(file.id);
      if (assetId != null) {
        await PhotoManager.editor.deleteWithIds([assetId]);
        await PhotoManager.clearFileCache();
      }
    } else {
      await match.file.delete();
    }
  }
  bumpDeviceState(ref);
  if (context.mounted) Navigator.pop(context);
}

Widget cloudMediaInfo(FileItem file) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(file.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      _InfoRow(icon: Icons.calendar_today_outlined, text: _formatDate(file.createdAt)),
      _InfoRow(icon: Icons.sd_storage_outlined, text: humanFileSize(file.totalSize)),
      _InfoRow(icon: Icons.image_outlined, text: file.mimeType),
      if (file.isMultiPart)
        _InfoRow(icon: Icons.layers_outlined, text: '${file.parts.length} parts'),
    ],
  );
}

// ---------------------------------------------------------------------------
// Local pages — an AssetEntity that lives only on the device.
// ---------------------------------------------------------------------------

class LocalImagePage extends ConsumerStatefulWidget {
  const LocalImagePage({super.key, required this.asset});
  final AssetEntity asset;

  @override
  ConsumerState<LocalImagePage> createState() => _LocalImagePageState();
}

class _LocalImagePageState extends ConsumerState<LocalImagePage> {
  File? _local;
  String? _error;

  final TransformationController _transform = TransformationController();
  // See _CloudImagePageState above for why: InteractiveViewer's own
  // pan/scale recognizer competes with ViewerPageChrome's vertical-drag
  // recognizer for the same pointer once zoomed in.
  final ValueNotifier<bool> _zoomed = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _transform.addListener(() {
      final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
      if (zoomed != _zoomed.value) _zoomed.value = zoomed;
    });
    widget.asset.file.then((f) {
      if (!mounted) return;
      if (f == null) {
        setState(() => _error = 'Could not read this photo from the device.');
      } else {
        setState(() => _local = f);
      }
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e.toString());
    });
  }

  @override
  void dispose() {
    _transform.dispose();
    _zoomed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)));
    }
    final local = _local;
    if (local == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ViewerPageChrome(
      actions: localMediaActions(context, ref, widget.asset, local),
      infoBuilder: (context) => localMediaInfo(widget.asset, local),
      gestureDisabled: _zoomed,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: Image.file(
            local,
            errorBuilder: (_, _, _) =>
                const Text('Could not display image.', style: TextStyle(color: Colors.white70)),
          ),
        ),
      ),
    );
  }
}

class LocalVideoPage extends ConsumerStatefulWidget {
  const LocalVideoPage({super.key, required this.asset});
  final AssetEntity asset;

  @override
  ConsumerState<LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends ConsumerState<LocalVideoPage> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  bool _ready = false;
  String? _error;
  File? _local;

  final TransformationController _transform = TransformationController();
  // See _CloudImagePageState for why this exists.
  final ValueNotifier<bool> _zoomed = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _transform.addListener(() {
      final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
      if (zoomed != _zoomed.value) _zoomed.value = zoomed;
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await widget.asset.file;
      if (file == null) throw Exception('Could not read this video from the device.');
      await _player.open(Media(file.path));
      if (mounted) setState(() { _ready = true; _local = file; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _player.dispose();
    _transform.dispose();
    _zoomed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)));
    }
    final local = _local;
    if (!_ready || local == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ViewerPageChrome(
      actions: localMediaActions(context, ref, widget.asset, local),
      infoBuilder: (context) => localMediaInfo(widget.asset, local),
      gestureDisabled: _zoomed,
      child: InteractiveViewer(
        transformationController: _transform,
        // Panning stays off for video: a single-finger drag needs to reach
        // the seek bar/tap-to-toggle-controls underneath undisturbed. Pinch
        // (scaleEnabled) still zooms in/out around the center.
        panEnabled: false,
        minScale: 1,
        maxScale: 5,
        child: Video(controller: _controller, controls: videoControlsWithSafeInsets),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared actions/info for a local device asset.
// ---------------------------------------------------------------------------

/// Tracks per-asset upload state so the viewer's Upload/Uploaded action
/// updates immediately after uploading, instead of only on the next rebuild.
/// Recomputes on every [deviceStateVersion] bump, so any upload/delete
/// anywhere in the app keeps this in sync.
final _uploadedProvider = Provider.family<bool, String>((ref, assetId) {
  ref.watch(deviceStateVersion);
  return BackupRegistry.instance.isUploaded(assetId);
});

List<ViewerAction> localMediaActions(
  BuildContext context,
  WidgetRef ref,
  AssetEntity asset,
  File localFile,
) {
  final uploaded = ref.watch(_uploadedProvider(asset.id));
  return [
    ViewerAction(
      icon: Icons.share_outlined,
      label: 'Share',
      onTap: () => SharePlus.instance.share(ShareParams(files: [XFile(localFile.path)])),
    ),
    // Cloud-backup status: Upload (pending) or Uploaded (done).
    ViewerAction(
      icon: uploaded ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
      label: uploaded ? 'Uploaded' : 'Upload',
      onTap: uploaded ? null : () => _uploadAsset(context, ref, asset),
    ),
    // Device-presence status: always on device here — informational.
    const ViewerAction(
      icon: Icons.smartphone,
      label: 'On device',
      onTap: null,
    ),
    ViewerAction(
      icon: Icons.playlist_add,
      label: 'Add to album',
      onTap: () async {
        final fileItemId = await _resolveFileItemId(context, ref, asset);
        if (fileItemId != null && context.mounted) {
          await addFileIdsToAlbum(context, ref, [fileItemId]);
        }
      },
    ),
    ViewerAction(
      icon: Icons.delete_outline,
      label: 'Delete',
      color: Colors.redAccent,
      onTap: () => _deleteAsset(context, ref, asset),
    ),
  ];
}

Future<void> _deleteAsset(BuildContext context, WidgetRef ref, AssetEntity asset) async {
  final registry = BackupRegistry.instance;
  final existsInCloud = registry.isUploaded(asset.id);

  final source = await askDeleteSource(
    context,
    existsOnDevice: true,
    existsInCloud: existsInCloud,
  );
  if (source == null || !context.mounted) return;

  try {
    var deletedFromDevice = false;
    var deviceDeleteCancelled = false;
    if (source == DeleteSource.device || source == DeleteSource.both) {
      // On Android 11+, deleting media this app didn't create shows a
      // separate SYSTEM confirmation dialog on top of ours — if it's
      // declined (or missed), Android reports nothing deleted.
      final deleted = await PhotoManager.editor.deleteWithIds([asset.id]);
      deletedFromDevice = deleted.isNotEmpty;
      deviceDeleteCancelled = !deletedFromDevice;
      if (deletedFromDevice) {
        await PhotoManager.clearFileCache();
        await ref.read(backupProvider.notifier).refreshDeviceAlbums();
      }
    }
    if (source == DeleteSource.cloud || source == DeleteSource.both) {
      final fileItemId = registry.fileItemIdFor(asset.id);
      FileItem? fileItem;
      if (fileItemId != null) {
        for (final f in ref.read(indexProvider).index.files) {
          if (f.id == fileItemId) { fileItem = f; break; }
        }
      }
      if (fileItem != null) await ref.read(indexProvider.notifier).deleteFiles([fileItem]);
    }
    bumpDeviceState(ref);

    if (!context.mounted) return;
    if (deviceDeleteCancelled && source == DeleteSource.device) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Delete cancelled — Android's own confirmation wasn't approved."),
      ));
      return;
    }
    // deleteFiles doesn't rethrow on failure — check explicitly so a failed
    // Telegram delete doesn't close the viewer as if it had succeeded.
    if (ref.read(indexProvider).mutationError != null) return;
    if (deletedFromDevice || source == DeleteSource.cloud) {
      Navigator.of(context).pop();
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }
}

Future<String?> _resolveFileItemId(BuildContext context, WidgetRef ref, AssetEntity asset) async {
  final existing = BackupRegistry.instance.fileItemIdFor(asset.id);
  if (existing != null) return existing;
  return _uploadAsset(context, ref, asset);
}

/// Uploads [asset] and links it in the backup registry. Returns the new
/// file's id, or null if the upload failed.
Future<String?> _uploadAsset(BuildContext context, WidgetRef ref, AssetEntity asset) async {
  try {
    final fileItem = await AssetUploadService.instance.uploadAndLink(ref, asset);
    bumpDeviceState(ref);
    return fileItem.id;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
    return null;
  }
}

Widget localMediaInfo(AssetEntity asset, File localFile) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(asset.title ?? 'Untitled',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      _InfoRow(icon: Icons.calendar_today_outlined, text: _formatDate(asset.createDateTime)),
      _InfoRow(icon: Icons.aspect_ratio_outlined, text: '${asset.width} × ${asset.height}'),
      FutureBuilder<int>(
        future: localFile.length(),
        builder: (context, snapshot) => _InfoRow(
          icon: Icons.sd_storage_outlined,
          text: snapshot.hasData ? humanFileSize(snapshot.data!) : '…',
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Shared small widgets/helpers.
// ---------------------------------------------------------------------------

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.white54),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final ampm = local.hour < 12 ? 'AM' : 'PM';
  final minute = local.minute.toString().padLeft(2, '0');
  return '${months[local.month - 1]} ${local.day}, ${local.year} · $hour:$minute $ampm';
}
