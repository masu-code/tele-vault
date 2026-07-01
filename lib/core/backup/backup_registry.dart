import 'package:shared_preferences/shared_preferences.dart';

/// Persists which device asset IDs have been uploaded and which device albums
/// have backup enabled. Uses SharedPreferences for simplicity (the sets are
/// small — one entry per photo/video on the device).
class BackupRegistry {
  static const _uploadedPrefix = 'bk_up_';
  static const _enabledKey = 'bk_enabled_albums';
  static const _linkPrefix = 'bk_link_';

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

  /// Records that the uploaded [fileItemId] originated from the local file at
  /// [localPath], so it can be recognized as already-on-device even though it
  /// was never explicitly "saved" via the download action.
  Future<void> linkLocalPath(String fileItemId, String localPath) =>
      _prefs!.setString('$_linkPrefix$fileItemId', localPath);

  String? localPathFor(String fileItemId) =>
      _prefs!.getString('$_linkPrefix$fileItemId');

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
