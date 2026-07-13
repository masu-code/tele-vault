import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/backup/asset_upload_service.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../core/download/download_service.dart';
import '../../download/providers/download_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../../preview/screens/mixed_media_viewer_screen.dart';
import '../../preview/widgets/add_to_album_sheet.dart';
import '../../preview/widgets/delete_source_dialog.dart';
import '../../profile/widgets/floating_profile_header.dart';
import '../../transfer/providers/transfer_queue_provider.dart';
import '../models/gallery_entry.dart';
import '../providers/gallery_feed_provider.dart';
import '../services/gallery_feed_service.dart';
import '../widgets/gallery_tile.dart';

/// Google Photos-style timeline of ALL media, grouped by month — both
/// already-uploaded cloud files and device-only photos/videos merged into
/// one feed (see [galleryFeedProvider]). Tap opens the full-screen viewer;
/// long-press (or right-click) starts multi-select, with upload/download,
/// add-to-album, and delete actions in the app bar.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  final Set<String> _selected = {};
  bool _selecting = false;
  final ScrollController _scrollController = ScrollController();

  /// Whether this device has granted (full or limited) photo library access.
  /// Null while the initial passive check is in flight; false shows the
  /// opt-in banner (never requested automatically — see initState).
  bool? _hasDeviceAccess;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      PhotoManager.getPermissionState(requestOption: const PermissionRequestOption())
          .then((s) {
        if (mounted) setState(() => _hasDeviceAccess = s.hasAccess);
      });
    } else {
      _hasDeviceAccess = false;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _grantDeviceAccess() async {
    final state = await PhotoManager.requestPermissionExtend();
    if (mounted) setState(() => _hasDeviceAccess = state.hasAccess);
    ref.invalidate(galleryFeedProvider);
  }

  void _exitSelection() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _toggle(GalleryEntry entry) {
    setState(() {
      if (!_selected.remove(entry.key)) _selected.add(entry.key);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _startSelection(GalleryEntry entry) {
    setState(() {
      _selecting = true;
      _selected.add(entry.key);
    });
  }

  List<GalleryEntry> _selectedEntries(List<GalleryEntry> flat) =>
      flat.where((e) => _selected.contains(e.key)).toList();

  Future<void> _shareSelected(List<GalleryEntry> flat) async {
    final selected = _selectedEntries(flat);
    if (selected.isEmpty) return;
    try {
      final locals = await Future.wait(selected.map((e) async {
        if (e.fileItem != null) return DownloadService.instance.downloadToCache(e.fileItem!);
        final f = await e.asset!.file;
        if (f == null) throw Exception('Could not read file from device.');
        return f;
      }));
      await SharePlus.instance.share(ShareParams(files: locals.map((f) => XFile(f.path)).toList()));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share: $e')));
      }
    }
  }

  void _uploadSelected(List<GalleryEntry> flat) {
    final toUpload =
        _selectedEntries(flat).where((e) => e.fileItem == null).map((e) => e.asset!).toList();
    if (toUpload.isEmpty) return;
    _exitSelection();
    ref.read(transferQueueProvider.notifier).enqueueUploads(toUpload);
  }

  void _downloadSelected(List<GalleryEntry> flat) {
    final toDownload = _selectedEntries(flat)
        .where((e) => e.fileItem != null && e.asset == null)
        .map((e) => e.fileItem!)
        .toList();
    if (toDownload.isEmpty) return;
    _exitSelection();
    ref.read(transferQueueProvider.notifier).enqueueDownloads(toDownload);
  }

  Future<void> _addSelectedToAlbum(List<GalleryEntry> flat) async {
    final selected = _selectedEntries(flat);
    if (selected.isEmpty) return;

    final fileIds = <String>[];
    String? uploadError;
    for (final entry in selected) {
      if (entry.fileItem != null) {
        fileIds.add(entry.fileItem!.id);
        continue;
      }
      // Device-only entries are auto-uploaded first — a vault album can only
      // reference cloud files.
      try {
        final uploadedItem = await AssetUploadService.instance.uploadAndLink(ref, entry.asset!);
        fileIds.add(uploadedItem.id);
      } catch (e) {
        uploadError = e.toString();
      }
    }
    if (fileIds.isNotEmpty) bumpDeviceState(ref);
    _exitSelection();

    if (fileIds.isEmpty) {
      if (uploadError != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $uploadError')));
      }
      return;
    }
    if (!mounted) return;
    await addFileIdsToAlbum(context, ref, fileIds);
    if (uploadError != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Some items could not be uploaded: $uploadError')),
      );
    }
  }

  Future<void> _deleteSelected(List<GalleryEntry> flat) async {
    final selected = _selectedEntries(flat);
    if (selected.isEmpty) return;

    final anyOnDevice = selected.any((e) => e.isOnDevice);
    final anyInCloud = selected.any((e) => e.isUploaded);
    final source = await askDeleteSource(context, existsOnDevice: anyOnDevice, existsInCloud: anyInCloud);
    if (source == null) return;

    if (source == DeleteSource.cloud || source == DeleteSource.both) {
      final cloudItems = selected.where((e) => e.fileItem != null).map((e) => e.fileItem!).toList();
      if (cloudItems.isNotEmpty) await ref.read(indexProvider.notifier).deleteFiles(cloudItems);
    }
    if (source == DeleteSource.device || source == DeleteSource.both) {
      final assetIds = selected.where((e) => e.asset != null).map((e) => e.asset!.id).toList();
      if (assetIds.isNotEmpty) {
        final deleted = await PhotoManager.editor.deleteWithIds(assetIds);
        await PhotoManager.clearFileCache();
        if (deleted.length < assetIds.length && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Some items weren't deleted — Android's own confirmation wasn't approved."),
          ));
        }
      }
    }
    bumpDeviceState(ref);
    _exitSelection();
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(galleryFeedProvider);
    final groupsAsync = ref.watch(galleryMonthGroupsProvider);
    final flat = feedAsync.valueOrNull ?? const <GalleryEntry>[];

    ref.listen(downloadProvider, (prev, next) {
      final msg = next.savedMessage ?? (next.error != null ? 'Failed: ${next.error}' : null);
      if (msg != null && (next.savedMessage != prev?.savedMessage || next.error != prev?.error)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    });
    ref.listen(indexProvider, (prev, next) {
      if (next.mutationError != null && next.mutationError != prev?.mutationError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: ${next.mutationError}')),
        );
      }
    });

    final selectedEntries = _selectedEntries(flat);
    final needsUpload = selectedEntries.any((e) => e.fileItem == null);
    final needsDownload = selectedEntries.any((e) => e.fileItem != null && e.asset == null);

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: _exitSelection),
              title: Text('${_selected.length} selected'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: 'Share',
                  onPressed: () => _shareSelected(flat),
                ),
                IconButton(
                  icon: const Icon(Icons.cloud_upload_outlined),
                  tooltip: 'Upload',
                  onPressed: needsUpload ? () => _uploadSelected(flat) : null,
                ),
                IconButton(
                  icon: const Icon(Icons.download_outlined),
                  tooltip: 'Download',
                  onPressed: needsDownload ? () => _downloadSelected(flat) : null,
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: 'Add to album',
                  onPressed: () => _addSelectedToAlbum(flat),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () => _deleteSelected(flat),
                ),
              ],
            )
          : null,
      body: Stack(
        children: [
          _body(context, groupsAsync, flat),
          if (!_selecting) const FloatingProfileHeader(title: 'Gallery'),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AsyncValue<List<GalleryMonthGroup>> groupsAsync,
    List<GalleryEntry> flat,
  ) {
    return groupsAsync.when(
      // Keep showing the current grid while the feed recomputes (e.g. after
      // each upload batch) instead of flashing a full-screen spinner.
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Could not load gallery: $e',
            textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54)),
      ),
      data: (groups) {
        if (groups.isEmpty) {
          return const Center(
            child: Text(
              'No photos or videos yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          );
        }
        final topInset =
            _selecting ? 2.0 : MediaQuery.of(context).padding.top + kToolbarHeight + 8;

        var index = 0; // running position in the flat list, for tap-to-open
        final slivers = <Widget>[
          SliverToBoxAdapter(child: SizedBox(height: topInset)),
          if (Platform.isAndroid && _hasDeviceAccess == false)
            SliverToBoxAdapter(child: _permissionBanner()),
        ];
        for (final group in groups) {
          final startIndex = index;
          slivers.add(SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            sliver: SliverToBoxAdapter(
              child: Text(monthLabel(group.month),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ));
          slivers.add(SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 120,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final entry = group.entries[i];
                  final flatIndex = startIndex + i;
                  return GalleryTile(
                    key: ValueKey(entry.key),
                    entry: entry,
                    selected: _selected.contains(entry.key),
                    onLongPress: () => _selecting ? _toggle(entry) : _startSelection(entry),
                    onTap: () {
                      if (_selecting) {
                        _toggle(entry);
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                MixedMediaViewerScreen(entries: flat, initialIndex: flatIndex),
                          ),
                        );
                      }
                    },
                  );
                },
                childCount: group.entries.length,
              ),
            ),
          ));
          index += group.entries.length;
        }

        return Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          interactive: true,
          child: RefreshIndicator(
            onRefresh: () async {
              GalleryFeedService.instance.invalidateCache();
              ref.invalidate(galleryFeedProvider);
              await ref.read(galleryFeedProvider.future);
            },
            // Builds tiles ~2 screens ahead of the viewport so their
            // thumbnail requests start before they're actually visible,
            // instead of popping in right at the edge of the screen.
            child: CustomScrollView(
              controller: _scrollController,
              scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
              slivers: slivers,
            ),
          ),
        );
      },
    );
  }

  Widget _permissionBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.photo_library_outlined, color: Color(0xFF2AABEE), size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Show photos from this device too, not just what\'s uploaded.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          TextButton(onPressed: _grantDeviceAccess, child: const Text('Allow')),
        ],
      ),
    );
  }
}
