import 'package:flutter/material.dart';

enum DeleteSource { device, cloud, both }

/// Always tells the user exactly where a delete will happen. If the item only
/// exists in one place, that's a plain confirm; if it exists in both, the
/// user explicitly picks device, cloud, or both.
Future<DeleteSource?> askDeleteSource(
  BuildContext context, {
  required bool existsOnDevice,
  required bool existsInCloud,
}) {
  if (existsOnDevice && existsInCloud) {
    return showDialog<DeleteSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete from where?'),
        content: const Text(
          'This item is both on your device and backed up in Telegram.\n\n'
          "If you delete from the device, Android will show its own confirmation "
          'popup right after this one — you need to approve that one too.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, DeleteSource.device),
            child: const Text('Device only'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, DeleteSource.cloud),
            child: const Text('Telegram only'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, DeleteSource.both),
            child: const Text('Both'),
          ),
        ],
      ),
    );
  }

  final source = existsOnDevice ? DeleteSource.device : DeleteSource.cloud;
  final where = existsOnDevice ? 'your device' : 'Telegram';
  return showDialog<DeleteSource>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete this file?'),
      content: Text(
        'This permanently removes it from $where.'
        '${existsOnDevice ? "\n\nAndroid will show its own confirmation popup right after this one — approve that one too." : ""}',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(ctx, source),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
}
