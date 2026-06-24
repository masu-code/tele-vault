import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../download/providers/download_provider.dart';
import '../../preview/screens/image_preview_screen.dart';
import '../../preview/screens/video_preview_screen.dart';
import '../../upload/providers/upload_provider.dart';
import '../../../models/file_item.dart';
import '../../../models/folder.dart';
import '../providers/index_provider.dart';
import '../widgets/file_thumbnail.dart';

/// File browser backed by the Telegram index. Supports navigating into folders;
/// uploads and new folders are created inside the folder currently open.
class ExplorerScreen extends ConsumerStatefulWidget {
  const ExplorerScreen({super.key});

  @override
  ConsumerState<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends ConsumerState<ExplorerScreen> {
  /// Stack of folders from root to the one currently open. Empty = root.
  final List<Folder> _path = [];

  String? get _currentFolderId => _path.isEmpty ? null : _path.last.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(indexProvider.notifier).load();
    });
  }

  void _openFolder(Folder folder) => setState(() => _path.add(folder));

  void _goUp() => setState(() => _path.removeLast());

  /// Images and videos preview in-app; everything else is downloaded and
  /// handed to the device's default handler.
  void _openFile(FileItem file) {
    final mime = file.mimeType;
    if (mime.startsWith('image/')) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ImagePreviewScreen(file: file)),
      );
    } else if (mime.startsWith('video/')) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => VideoPreviewScreen(file: file)),
      );
    } else {
      ref.read(downloadProvider.notifier).downloadAndOpen(file);
    }
  }

  Future<void> _createFolderDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(indexProvider.notifier).createFolder(name, parentId: _currentFolderId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(indexProvider);
    final upload = ref.watch(uploadProvider);
    final download = ref.watch(downloadProvider);
    final folders = state.index.foldersIn(_currentFolderId);
    final files = state.index.filesIn(_currentFolderId);

    ref.listen(uploadProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: ${next.error}')),
        );
      }
    });
    ref.listen(downloadProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: ${next.error}')),
        );
      }
    });

    final atRoot = _path.isEmpty;

    return Scaffold(
      appBar: AppBar(
        leading: atRoot ? null : IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goUp),
        title: Text(atRoot ? 'TeleVault' : _path.last.name),
        actions: [
          if (state.isSaving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(indexProvider.notifier).load(),
          ),
        ],
      ),
      floatingActionButton: Column(
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
      body: Column(
        children: [
          if (!atRoot) _breadcrumb(),
          if (upload.isUploading) _uploadBanner(upload),
          Expanded(child: _buildBody(state, download, folders, files)),
        ],
      ),
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
              'Uploading ${upload.fileName ?? ''}  ${(upload.progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: upload.progress == 0 ? null : upload.progress),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
      IndexState state, DownloadState download, List folders, List files) {
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
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
            leading: const Icon(Icons.folder, color: Color(0xFF2AABEE)),
            title: Text(folder.name),
            onTap: () => _openFolder(folder),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => ref.read(indexProvider.notifier).removeFolder(folder.id),
            ),
          ),
        for (final file in files)
          ListTile(
            leading: FileThumbnail(file: file, fallbackIcon: _iconFor(file)),
            title: Text(file.name),
            subtitle: Text('${file.parts.length} part(s) · ${_humanSize(file.totalSize)}'),
            onTap: () => _openFile(file),
            trailing: download.fileId == file.id
                ? SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: download.progress == 0 ? null : download.progress,
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.download_outlined),
                    onPressed: download.isDownloading
                        ? null
                        : () => ref.read(downloadProvider.notifier).downloadAndOpen(file),
                  ),
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
