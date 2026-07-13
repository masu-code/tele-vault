import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../explorer/providers/index_provider.dart';

/// Shows the "add to album" bottom sheet (existing albums + "New album…")
/// for [fileIds] and applies the choice. Shared by every entry point that
/// needs this exact flow (Gallery's multi-select, the cloud viewer, the
/// local device-asset viewer) — previously duplicated 3x with drift between
/// copies (e.g. one of them never checked for a failed write before
/// declaring success).
Future<void> addFileIdsToAlbum(BuildContext context, WidgetRef ref, List<String> fileIds) async {
  if (fileIds.isEmpty) return;
  final index = ref.read(indexProvider).index;
  final albums = index.albums;

  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New album…'),
            onTap: () => Navigator.pop(ctx, '__new__'),
          ),
          if (albums.isNotEmpty) const Divider(height: 1),
          for (final a in albums)
            ListTile(
              leading: const Icon(Icons.photo_album_outlined),
              title: Text(a.name),
              // filesByIds skips ids that no longer resolve to a file — the
              // count should reflect what's actually shown, not the raw
              // (possibly stale) fileIds list length.
              subtitle: Text('${index.filesByIds(a.fileIds).length} item(s)'),
              onTap: () => Navigator.pop(ctx, a.id),
            ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  if (choice == '__new__') {
    final name = await _promptAlbumName(context);
    if (name == null || name.isEmpty) return;
    await ref.read(indexProvider.notifier).createAlbum(name, fileIds: fileIds);
  } else {
    await ref.read(indexProvider.notifier).addToAlbum(choice, fileIds);
  }

  if (ref.read(indexProvider).mutationError != null) return;
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        fileIds.length == 1 ? 'Added to album' : 'Added ${fileIds.length} item(s) to album',
      ),
    ));
  }
}

Future<String?> _promptAlbumName(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('New album'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Album name'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    ),
  );
}
