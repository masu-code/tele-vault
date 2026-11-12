import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/album.dart';
import '../../../models/file_item.dart';
import '../../explorer/providers/index_provider.dart';

/// What the Albums grid needs from one vault album: the number of members that
/// still resolve to a non-archived file, and the first one as the cover.
class VaultAlbumSummary {
  const VaultAlbumSummary({
    required this.album,
    required this.itemCount,
    required this.cover,
  });

  final Album album;

  /// Files actually resolvable in the index — not `album.fileIds.length`,
  /// which would overcount if the album still references a file id that no
  /// longer exists (e.g. a stale index written by an older app version that
  /// didn't clean up album membership on delete).
  final int itemCount;
  final FileItem? cover;

  @override
  bool operator ==(Object other) =>
      other is VaultAlbumSummary &&
      other.album.id == album.id &&
      other.album.name == album.name &&
      other.itemCount == itemCount &&
      other.cover?.id == cover?.id;

  @override
  int get hashCode => Object.hash(album.id, album.name, itemCount, cover?.id);
}

class VaultAlbumSummaries {
  const VaultAlbumSummaries(this.items);

  final List<VaultAlbumSummary> items;

  @override
  bool operator ==(Object other) {
    if (other is! VaultAlbumSummaries) return false;
    if (other.items.length != items.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (items[i] != other.items[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(items.length, items.isEmpty ? 0 : items.first.hashCode);
}

/// Per-album counts and covers, computed once per index change (one id map for
/// all albums) instead of once per album per build. The value has structural
/// equality, so an index change that doesn't touch any album's count or cover
/// (a plain upload, a rename of an unrelated file) does not notify the Albums
/// screen at all.
final vaultAlbumSummariesProvider = Provider<VaultAlbumSummaries>((ref) {
  final albums = ref.watch(indexProvider.select((s) => s.index.albums));
  final files = ref.watch(indexProvider.select((s) => s.index.files));
  if (albums.isEmpty) return const VaultAlbumSummaries([]);
  final byId = {for (final f in files) f.id: f};
  return VaultAlbumSummaries([
    for (final album in albums)
      () {
        var count = 0;
        FileItem? cover;
        for (final id in album.fileIds) {
          final f = byId[id];
          if (f == null || f.archived) continue;
          cover ??= f;
          count++;
        }
        return VaultAlbumSummary(album: album, itemCount: count, cover: cover);
      }(),
  ]);
});
