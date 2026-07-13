import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../features/explorer/providers/index_provider.dart';
import '../../models/file_item.dart';
import '../upload/upload_service.dart';
import 'backup_registry.dart';

/// Uploads a device [AssetEntity] on demand and links it in [BackupRegistry],
/// so it's recognized everywhere as "uploaded" without a full backup sync.
/// Shared by the device-asset viewer, Gallery's batch Upload action, and
/// Gallery's add-to-album auto-upload for not-yet-uploaded selections.
class AssetUploadService {
  AssetUploadService._();
  static final AssetUploadService instance = AssetUploadService._();

  /// Uploads [asset], adds it to the index, and links it in [BackupRegistry].
  /// Throws on any failure — including a failed index write, which
  /// [IndexNotifier.addFile] otherwise swallows into `mutationError` instead
  /// of throwing (a silent failure here would let the asset finish uploading
  /// to Telegram while never becoming visible in the app). Does not call
  /// [bumpDeviceState] — callers uploading a batch should bump once at the
  /// end, not once per item.
  Future<FileItem> uploadAndLink(WidgetRef ref, AssetEntity asset) async {
    final file = await asset.file;
    if (file == null) throw Exception('Could not read file from device.');

    final fileItem = await UploadService.instance.uploadFile(file);
    await ref.read(indexProvider.notifier).addFile(fileItem);
    final indexError = ref.read(indexProvider).mutationError;
    if (indexError != null) {
      throw Exception('Uploaded but failed to save to index: $indexError');
    }

    final registry = BackupRegistry.instance;
    await registry.markUploaded(asset.id);
    await registry.linkLocalPath(fileItem.id, file.path);
    await registry.linkFileItem(asset.id, fileItem.id);
    return fileItem;
  }

  /// The asset's existing cloud file id, or uploads it on demand and returns
  /// the new one. Throws on upload failure (see [uploadAndLink]).
  Future<String> resolveFileItemId(WidgetRef ref, AssetEntity asset) async {
    final existing = BackupRegistry.instance.fileItemIdFor(asset.id);
    if (existing != null) return existing;
    return (await uploadAndLink(ref, asset)).id;
  }
}
