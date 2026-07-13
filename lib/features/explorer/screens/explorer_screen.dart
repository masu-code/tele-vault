import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../download/providers/download_provider.dart';
import '../../preview/screens/media_viewer_screen.dart';
import '../../preview/widgets/delete_source_dialog.dart';
import '../../profile/widgets/floating_profile_header.dart';
import '../../upload/providers/upload_provider.dart';
import '../../../models/file_index.dart';
import '../../../models/file_item.dart';
import '../../../models/folder.dart';
import '../providers/index_provider.dart';
import '../widgets/file_thumbnail.dart';
import '../widgets/save_to_device_button.dart';

/// A move destination chosen by the user. `null` return from the picker means
/// cancelled; a [_MoveTarget] with a null [folderId] means the root.
class _MoveTarget {
  final String? folderId;
  const _MoveTarget(this.folderId);
}

/// Full file manager: navigate folders, upload (picker + drag-drop), and a
/// multi-select mode with move / rename / save-to-device / delete.
class ExplorerScreen extends ConsumerStatefulWidget {
  const ExplorerScreen({super.key});

  @override
  ConsumerState<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends ConsumerState<ExplorerScreen> {
  /// Stack of folders from root to the one currently open. Empty = root.
  final List<Folder> _path = [];

  final Set<String> _selFiles = {};
  final Set<String> _selFolders = {};
  bool _selecting = false;

  String? get _currentFolderId => _path.isEmpty ? null : _path.last.id;
  int get _selCount => _selFiles.length + _selFolders.length;

  void _openFolder(Folder folder) => setState(() => _path.add(folder));
  void _goUp() => setState(() => _path.removeLast());

  void _exitSelection() => setState(() {
        _selecting = false;
        _selFiles.clear();
        _selFolders.clear();
      });

  void _toggleFile(FileItem f) => setState(() {
        if (!_selFiles.remove(f.id)) _selFiles.add(f.id);
        _selecting = _selCount > 0;
      });

  void _toggleFolder(Folder f) => setState(() {
        if (!_selFolders.remove(f.id)) _selFolders.add(f.id);
        _selecting = _selCount > 0;
      });

  /// Images and videos preview in-app; everything else opens with the system.
  void _openFile(FileItem file) {
    final mime = file.mimeType;
    if (mime.startsWith('image/') || mime.startsWith('video/')) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MediaViewerScreen(items: [file], initialIndex: 0)),
      );
    } else {
      ref.read(downloadProvider.notifier).openWithSystem(file);
    }
  }

  Future<String?> _promptName(String title, {String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _createFolderDialog() async {
    final name = await _promptName('New folder');
    if (name != null && name.isNotEmpty) {
      await ref.read(indexProvider.notifier).createFolder(name, parentId: _currentFolderId);
    }
  }

  Future<void> _renameSelected(FileIndex index) async {
    if (_selFiles.length == 1 && _selFolders.isEmpty) {
      final file = index.files.firstWhere((f) => f.id == _selFiles.first);
      final name = await _promptName('Rename file', initial: file.name);
      if (name != null && name.isNotEmpty) {
        await ref.read(indexProvider.notifier).renameFile(file.id, name);
      }
    } else if (_selFolders.length == 1 && _selFiles.isEmpty) {
      final folder = index.folders.firstWhere((f) => f.id == _selFolders.first);
      final name = await _promptName('Rename folder', initial: folder.name);
      if (name != null && name.isNotEmpty) {
        await ref.read(indexProvider.notifier).renameFolder(folder.id, name);
      }
    }
    _exitSelection();
  }

  Future<void> _moveSelected(FileIndex index) async {
    // Can't move a folder into itself or its own subtree.
    final excluded = <String>{..._selFolders};
    for (final fid in _selFolders) {
      excluded.addAll(index.descendantFolderIds(fid));
    }
    final candidates =
        index.folders.where((f) => !excluded.contains(f.id)).toList();
    final byId = {for (final f in index.folders) f.id: f};

    String pathOf(Folder f) {
      final names = <String>[];
      Folder? cur = f;
      while (cur != null) {
        names.insert(0, cur.name);
        cur = cur.parentId == null ? null : byId[cur.parentId];
      }
      return names.join(' / ');
    }

    final target = await showModalBottomSheet<_MoveTarget>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Move to…', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Root'),
              onTap: () => Navigator.pop(ctx, const _MoveTarget(null)),
            ),
            for (final f in candidates)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(pathOf(f)),
                onTap: () => Navigator.pop(ctx, _MoveTarget(f.id)),
              ),
          ],
        ),
      ),
    );
    if (target == null) return;
    await ref
        .read(indexProvider.notifier)
        .moveItems(_selFiles.toList(), _selFolders.toList(), target.folderId);
    _exitSelection();
  }

  Future<void> _saveSelected(FileIndex index) async {
    final files = index.files.where((f) => _selFiles.contains(f.id)).toList();
    _exitSelection();
    await ref.read(downloadProvider.notifier).saveManyToDevice(files);
  }

  Future<void> _deleteSelected(FileIndex index) async {
    final files = index.files.where((f) => _selFiles.contains(f.id)).toList();
    final folderIds = _selFolders.toList();
    if (files.isEmpty && folderIds.isEmpty) return;

    final registry = BackupRegistry.instance;
    // Same lookup the on-device icon uses — checking BackupRegistry.localPathFor
    // alone misses files saved via the explicit "Save to device" download.
    final matches = await Future.wait(files.map(LocalFileService.instance.existingLocalFile));
    final anyOnDevice = matches.any((m) => m != null);
    if (!mounted) return;

    final source = await askDeleteSource(context, existsOnDevice: anyOnDevice, existsInCloud: true);
    if (source == null) return;

    if (source == DeleteSource.cloud || source == DeleteSource.both) {
      await ref.read(indexProvider.notifier).deleteItems(files, folderIds);
    } else if (folderIds.isNotEmpty) {
      // Device-only: keep the cloud files, just remove selected folders.
      await ref.read(indexProvider.notifier).deleteItems([], folderIds);
    }
    if (source == DeleteSource.device || source == DeleteSource.both) {
      final assetIds = <String>[];
      for (var i = 0; i < files.length; i++) {
        final match = matches[i];
        if (match == null) continue;
        if (match.isLinkedAsset) {
          final id = registry.assetIdForFileItem(files[i].id);
          if (id != null) assetIds.add(id);
        } else {
          await match.file.delete();
        }
      }
      if (assetIds.isNotEmpty) {
        await PhotoManager.editor.deleteWithIds(assetIds);
        await PhotoManager.clearFileCache();
      }
    }
    bumpDeviceState(ref);
    _exitSelection();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(indexProvider);
    final upload = ref.watch(uploadProvider);
    final index = state.index;
    final folders = index.foldersIn(_currentFolderId);
    final files = index.filesIn(_currentFolderId);

    ref.listen(uploadProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: ${next.error}')),
        );
      }
    });
    ref.listen(indexProvider, (prev, next) {
      if (next.mutationError != null && next.mutationError != prev?.mutationError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: ${next.mutationError}')),
        );
      }
    });
    ref.listen(downloadProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${next.error}')));
      }
      if (next.savedMessage != null && next.savedMessage != prev?.savedMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.savedMessage!)));
      }
    });

    final atRoot = _path.isEmpty;
    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight;

    return Scaffold(
      appBar: _selecting ? _selectionAppBar(index) : null,
      floatingActionButton: _selecting
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.small(
                  heroTag: 'newFolder',
                  onPressed: _createFolderDialog,
                  child: const Icon(Icons.create_new_folder_outlined),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'upload',
                  onPressed: upload.isUploading
                      ? null
                      : () => ref.read(uploadProvider.notifier).pickAndUpload(folderId: _currentFolderId),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload'),
                ),
              ],
            ),
      body: Stack(
        children: [
          DropTarget(
            onDragDone: (detail) {
              final paths = detail.files.map((f) => f.path).toList();
              ref.read(uploadProvider.notifier).uploadPaths(paths, folderId: _currentFolderId);
            },
            child: Column(
              children: [
                SizedBox(height: _selecting ? 0 : topInset),
                if (_path.isNotEmpty) _breadcrumb(),
                if (upload.isUploading) _uploadBanner(upload),
                Expanded(child: _buildBody(state, folders, files)),
              ],
            ),
          ),
          if (!_selecting)
            FloatingProfileHeader(
              title: atRoot ? 'Files' : _path.last.name,
              onBack: atRoot ? null : _goUp,
              actions: [
                if (state.isSaving)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => ref.read(indexProvider.notifier).load(),
                ),
              ],
            ),
        ],
      ),
    );
  }

  PreferredSizeWidget _selectionAppBar(FileIndex index) {
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), onPressed: _exitSelection),
      title: Text('$_selCount selected'),
      actions: [
        if (_selCount == 1)
          IconButton(
            icon: const Icon(Icons.drive_file_rename_outline),
            tooltip: 'Rename',
            onPressed: () => _renameSelected(index),
          ),
        IconButton(
          icon: const Icon(Icons.drive_file_move_outline),
          tooltip: 'Move to folder',
          onPressed: () => _moveSelected(index),
        ),
        if (_selFiles.isNotEmpty) ...[
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share',
            onPressed: () => shareCloudFiles(
              context,
              index.filesByIds(_selFiles.toList()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Save to device',
            onPressed: () => _saveSelected(index),
          ),
        ],
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
          onPressed: () => _deleteSelected(index),
        ),
      ],
    );
  }

  Widget _breadcrumb() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: const Color(0xFF14303F),
      child: Text(
        'Root / ${_path.map((f) => f.name).join(' / ')}',
        style: const TextStyle(fontSize: 12, color: Colors.white70),
      ),
    );
  }

  Widget _uploadBanner(UploadState upload) {
    return Material(
      color: const Color(0xFF14303F),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              upload.totalCount > 1
                  ? 'Uploading ${upload.currentIndex}/${upload.totalCount}: ${upload.fileName ?? ''}  ${(upload.progress * 100).toStringAsFixed(0)}%'
                  : 'Uploading ${upload.fileName ?? ''}  ${(upload.progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: upload.progress == 0 ? null : upload.progress),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(IndexState state, List<Folder> folders, List<FileItem> files) {
    if (state.isLoading) return const Center(child: CircularProgressIndicator());
    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text(state.error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    if (folders.isEmpty && files.isEmpty) {
      return const Center(
        child: Text('Empty folder.\nTap + to create a folder or Upload a file.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
      );
    }
    return ListView(
      children: [
        for (final folder in folders)
          ListTile(
            key: ValueKey('folder_${folder.id}'),
            selected: _selFolders.contains(folder.id),
            selectedTileColor: const Color(0x222AABEE),
            leading: const Icon(Icons.folder, color: Color(0xFF2AABEE)),
            title: Text(folder.name),
            onTap: () => _selecting ? _toggleFolder(folder) : _openFolder(folder),
            onLongPress: () => _toggleFolder(folder),
            trailing: _selecting
                ? Icon(_selFolders.contains(folder.id)
                    ? Icons.check_circle
                    : Icons.circle_outlined)
                : null,
          ),
        for (final file in files)
          ListTile(
            key: ValueKey('file_${file.id}'),
            selected: _selFiles.contains(file.id),
            selectedTileColor: const Color(0x222AABEE),
            leading: FileThumbnail(
              key: ValueKey('thumb_${file.id}'),
              file: file,
              fallbackIcon: _iconFor(file),
            ),
            title: Text(file.name),
            subtitle: Text('${file.parts.length} part(s) · ${_humanSize(file.totalSize)}'),
            onTap: () => _selecting ? _toggleFile(file) : _openFile(file),
            onLongPress: () => _toggleFile(file),
            trailing: _selecting
                ? Icon(_selFiles.contains(file.id)
                    ? Icons.check_circle
                    : Icons.circle_outlined)
                : SaveToDeviceButton(file: file),
          ),
      ],
    );
  }

  static IconData _iconFor(FileItem file) {
    final mime = file.mimeType;
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _humanSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}
