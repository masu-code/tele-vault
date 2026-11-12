import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../features/explorer/providers/index_provider.dart';
import '../../models/file_item.dart';
import '../upload/upload_service.dart';
import 'backup_registry.dart';

/// Uploads [file] (the original of device asset [assetId]) with [upload] and
/// writes it to the index the same way the transfer queue does: a
/// pending-index row right after the upload succeeds, then
/// [indexPendingUploads] through [IndexNotifier.applyAndSave], which commits
/// the registry links (uploaded flag, local path, asset<->file) only for what
/// the written index holds.
///
/// Returns the [FileItem] the asset is linked to in the written index (the
/// new upload, or the surviving file when the rebase dropped it as a
/// duplicate). Throws when the index save fails or the upload is not in the
/// written index: nothing is then marked uploaded, and the pending-index row
/// keeps the asset from being uploaded again until a queue run indexes it.
Future<FileItem> uploadAndIndexAsset({
  required String assetId,
  required File file,
  required Future<FileItem> Function(File file) upload,
  required IndexNotifier index,
  required BackupRegistry registry,
}) async {
  await registry.init();
  final item = await upload(file);
  try {
    await registry.addPendingIndex(
      assetId: assetId,
      fileItemId: item.id,
      itemJson: pendingItemJson(item),
      path: file.path,
    );
  } catch (e) {
    debugPrint('TVUPLOAD: pending-index row not written (${e.runtimeType})');
  }
  final PendingIndexResult r;
  try {
    r = await indexPendingUploads(
      uploads: [(item: item, assetId: assetId, path: file.path)],
      save: (addMissing) async {
        var dropped = const <String>[];
        final written = await index.applyAndSave(
          addMissing,
          onDropped: (ids) => dropped = ids,
        );
        return (index: written, dropped: dropped);
      },
      commitUploads: registry.commitUploads,
      unlinkFileItem: registry.unlinkFileItem,
      removePending: registry.removePendingIndex,
    );
  } catch (e) {
    throw Exception('Uploaded but failed to save to index: $e');
  }
  final link = r.links.where((l) => l.assetId == assetId).firstOrNull;
  final linked = link == null
      ? null
      : r.written.files.where((f) => f.id == link.fileItemId).firstOrNull;
  if (linked == null) {
    throw Exception('Uploaded but not found in the saved index.');
  }
  return linked;
}

/// Uploads a device [AssetEntity] on demand and links it in [BackupRegistry],
/// so it's recognized everywhere as "uploaded" without a full backup sync.
/// Shared by the device-asset viewer, Gallery's batch Upload action, and
/// Gallery's add-to-album auto-upload for not-yet-uploaded selections.
class AssetUploadService {
  AssetUploadService._();
  static final AssetUploadService instance = AssetUploadService._();

  /// Uploads [asset], adds it to the index, and links it in [BackupRegistry]
  /// (see [uploadAndIndexAsset]). Throws on any failure, including a failed
  /// index write; the asset is then not marked uploaded. Does not call
  /// [bumpDeviceState] — callers uploading a batch should bump once at the
  /// end, not once per item.
  Future<FileItem> uploadAndLink(WidgetRef ref, AssetEntity asset) async {
    final file = await asset.file;
    if (file == null) throw Exception('Could not read file from device.');
    return uploadAndLinkFile(
      ref,
      asset.id,
      file,
      takenAtMs: assetTakenAtMs(asset),
    );
  }

  /// [uploadAndLink] for a [file] the caller already resolved (e.g. the
  /// asset's original). [takenAtMs]: see [UploadService.uploadFile].
  Future<FileItem> uploadAndLinkFile(
    WidgetRef ref,
    String assetId,
    File file, {
    int? takenAtMs,
  }) =>
      uploadAndIndexAsset(
        assetId: assetId,
        file: file,
        upload: (f) =>
            UploadService.instance.uploadFile(f, takenAtMs: takenAtMs),
        index: ref.read(indexProvider.notifier),
        registry: BackupRegistry.instance,
      );

  /// The asset's existing cloud file id, or uploads it on demand and returns
  /// the new one. Throws on upload failure (see [uploadAndLink]).
  Future<String> resolveFileItemId(WidgetRef ref, AssetEntity asset) async {
    final existing = BackupRegistry.instance.fileItemIdFor(asset.id);
    if (existing != null) return existing;
    return (await uploadAndLink(ref, asset)).id;
  }
}
