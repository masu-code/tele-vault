import 'package:shared_preferences/shared_preferences.dart';

/// Persists which device asset IDs have been uploaded and which device albums
/// have backup enabled. Uses SharedPreferences for simplicity (the sets are
/// small — one entry per photo/video on the device).
class BackupRegistry {
  static const _uploadedPrefix = 'bk_up_';
  static const _enabledKey = 'bk_enabled_albums';
  static const _linkPrefix = 'bk_link_';
  static const _fileItemPrefix = 'bk_item_';
  static const _assetForFileItemPrefix = 'bk_asset_';

  static final instance = BackupRegistry._();
  BackupRegistry._();

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  bool isUploaded(String assetId) =>
      _prefs!.getBool('$_uploadedPrefix$assetId') ?? false;

  Future<void> markUploaded(String assetId) =>
      _prefs!.setBool('$_uploadedPrefix$assetId', true);

  /// Clears the "uploaded" flag — used when an asset is found marked
  /// uploaded but with no matching entry in the actual index (e.g. the app
  /// was killed between marking it uploaded and linking it to its file, or
  /// between uploading and the index write actually persisting). Treating it
  /// as not-yet-uploaded again is the safe default: it gets excluded from
  /// "free up storage" candidates and picked up by the next backup pass
  /// instead of silently trusting a link that was never confirmed.
  Future<void> clearUploaded(String assetId) =>
      _prefs!.remove('$_uploadedPrefix$assetId');

  /// All device asset ids known to already be backed up to Telegram — used to
  /// find candidates for freeing up local storage.
  Set<String> get uploadedAssetIds => _prefs!
      .getKeys()
      .where((k) => k.startsWith(_uploadedPrefix) && (_prefs!.getBool(k) ?? false))
      .map((k) => k.substring(_uploadedPrefix.length))
      .toSet();

  /// Records that the uploaded [fileItemId] originated from the local file at
  /// [localPath], so it can be recognized as already-on-device even though it
  /// was never explicitly "saved" via the download action.
  Future<void> linkLocalPath(String fileItemId, String localPath) =>
      _prefs!.setString('$_linkPrefix$fileItemId', localPath);

  String? localPathFor(String fileItemId) =>
      _prefs!.getString('$_linkPrefix$fileItemId');

  /// Records which [FileItem] id a device [assetId] was uploaded as, so an
  /// already-uploaded device photo can be added to a vault album (which is
  /// keyed by file id, not device asset id) without re-uploading it. Also
  /// records the reverse link, so a cloud FileItem can find its device asset
  /// (e.g. to offer "delete from device too").
  Future<void> linkFileItem(String assetId, String fileItemId) async {
    await _prefs!.setString('$_fileItemPrefix$assetId', fileItemId);
    await _prefs!.setString('$_assetForFileItemPrefix$fileItemId', assetId);
  }

  String? fileItemIdFor(String assetId) =>
      _prefs!.getString('$_fileItemPrefix$assetId');

  String? assetIdForFileItem(String fileItemId) =>
      _prefs!.getString('$_assetForFileItemPrefix$fileItemId');

  /// Clears every registry entry tied to a cloud file that's being deleted
  /// from Telegram: the fileItem→path link, the fileItem↔asset links, and —
  /// critically — the "uploaded" flag on its device asset (if any). Without
  /// this, a deleted-from-Telegram file's original device asset keeps
  /// reporting as "safely backed up", so auto-backup never re-uploads it and
  /// Free Up Storage can offer to delete its last remaining copy.
  Future<void> unlinkFileItem(String fileItemId) async {
    await _prefs!.remove('$_linkPrefix$fileItemId');
    final assetId = assetIdForFileItem(fileItemId);
    await _prefs!.remove('$_assetForFileItemPrefix$fileItemId');
    if (assetId != null) {
      await _prefs!.remove('$_fileItemPrefix$assetId');
      await _prefs!.remove('$_uploadedPrefix$assetId');
    }
  }

  List<String> get enabledAlbumIds =>
      _prefs!.getStringList(_enabledKey) ?? [];

  bool isAlbumEnabled(String albumId) => enabledAlbumIds.contains(albumId);

  Future<void> setAlbumEnabled(String albumId, {required bool enabled}) async {
    final current = enabledAlbumIds;
    if (enabled && !current.contains(albumId)) {
      await _prefs!.setStringList(_enabledKey, [...current, albumId]);
    } else if (!enabled) {
      await _prefs!
          .setStringList(_enabledKey, current.where((id) => id != albumId).toList());
    }
  }
}
