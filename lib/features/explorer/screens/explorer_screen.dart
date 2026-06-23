import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../upload/providers/upload_provider.dart';
import '../providers/index_provider.dart';

/// Minimal explorer wired to the Telegram-backed index. Phase 3 expands this
/// into the full file browser; for now it proves the index round-trips: it
/// loads on entry and folder create/delete writes back to Saved Messages.
class ExplorerScreen extends ConsumerStatefulWidget {
  const ExplorerScreen({super.key});

  @override
  ConsumerState<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends ConsumerState<ExplorerScreen> {
  @override
  void initState() {
    super.initState();
    // Load the index once the screen is shown (user is authenticated here).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(indexProvider.notifier).load();
    });
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
      await ref.read(indexProvider.notifier).createFolder(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(indexProvider);
    final upload = ref.watch(uploadProvider);
    final folders = state.index.foldersIn(null);
    final files = state.index.filesIn(null);

    ref.listen(uploadProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: ${next.error}')),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('TeleVault'),
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
                : () => ref.read(uploadProvider.notifier).pickAndUpload(),
            icon: const Icon(Icons.upload_file),
            label: const Text('Upload'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (upload.isUploading) _uploadBanner(upload),
          Expanded(child: _buildBody(state, folders, files)),
        ],
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

  Widget _buildBody(IndexState state, List folders, List files) {
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
        child: Text('Empty vault.\nTap + to create a folder.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
      );
    }
    return ListView(
      children: [
        for (final folder in folders)
          ListTile(
            leading: const Icon(Icons.folder, color: Color(0xFF2AABEE)),
            title: Text(folder.name),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => ref.read(indexProvider.notifier).removeFolder(folder.id),
            ),
          ),
        for (final file in files)
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(file.name),
            subtitle: Text('${file.parts.length} part(s) · ${file.totalSize} B'),
          ),
      ],
    );
  }
}
