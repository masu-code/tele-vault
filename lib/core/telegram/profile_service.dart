import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:t/t.dart' as t;
import 'client.dart';

/// Basic info about the logged-in Telegram account, for the profile header.
class TelegramProfile {
  final String name;
  final String? phone;
  final File? avatar;

  const TelegramProfile({required this.name, this.phone, this.avatar});
}

/// Fetches the logged-in user's display name, phone, and profile photo
/// (small size) from Telegram, caching the photo to disk.
class ProfileService {
  ProfileService._();
  static final ProfileService instance = ProfileService._();

  Future<TelegramProfile> fetchProfile() async {
    final result = await TelegramService.instance
        .call((c) => c.users.getFullUser(id: const t.InputUserSelf()));
    if (result.error != null) {
      throw ProfileException('getFullUser failed: ${result.error!.errorMessage}');
    }

    final userFull = result.result;
    if (userFull is! t.UsersUserFull) {
      throw ProfileException('Unexpected getFullUser response type.');
    }

    final self = userFull.users.whereType<t.User>().isNotEmpty
        ? userFull.users.whereType<t.User>().first
        : null;
    final name = [self?.firstName, self?.lastName]
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .join(' ');

    File? avatar;
    final fullUser = userFull.fullUser;
    if (fullUser is t.UserFull) {
      final photo = fullUser.profilePhoto;
      if (photo is t.Photo) {
        avatar = await _downloadAvatar(photo);
      }
    }

    return TelegramProfile(
      name: name.isEmpty ? (self?.phone ?? 'Telegram account') : name,
      phone: self?.phone,
      avatar: avatar,
    );
  }

  Future<File?> _downloadAvatar(t.Photo photo) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'televault_cache'));
    await dir.create(recursive: true);
    // Keyed by photo id so a changed avatar is re-downloaded automatically.
    final file = File(p.join(dir.path, 'profile_avatar_${photo.id}.jpg'));
    if (await file.exists()) return file;

    final location = t.InputPeerPhotoFileLocation(
      big: false,
      peer: const t.InputPeerSelf(),
      photoId: photo.id,
    );
    final result = await TelegramService.instance.call((c) => c.upload.getFile(
      precise: false,
      cdnSupported: false,
      location: location,
      offset: 0,
      limit: 512 * 1024,
    ));
    if (result.error != null) return null;
    final uploaded = result.result;
    if (uploaded is! t.UploadFile || uploaded.bytes.isEmpty) return null;

    await file.writeAsBytes(uploaded.bytes);
    return file;
  }
}

class ProfileException implements Exception {
  final String message;
  ProfileException(this.message);
  @override
  String toString() => 'ProfileException: $message';
}
