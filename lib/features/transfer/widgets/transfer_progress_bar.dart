import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/transfer_queue_provider.dart';

/// Sync-progress card shown inside [AccountSheet] while the background
/// transfer queue is active — styled to match that sheet's other cards
/// (e.g. the device storage card). Renders nothing when idle.
class TransferProgressBar extends ConsumerWidget {
  const TransferProgressBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(transferQueueProvider);
    if (!t.active) return const SizedBox.shrink();

    final verb = t.kind == TransferKind.upload ? 'Uploading' : 'Downloading';
    final icon = t.kind == TransferKind.upload ? Icons.cloud_upload_outlined : Icons.cloud_download_outlined;
    final label = t.canceling ? 'Finishing…' : '$verb ${t.done}/${t.total}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: const Color(0xFF2AABEE)),
              const SizedBox(width: 8),
              Expanded(child: Text(label)),
              if (t.failed > 0)
                Text('${t.failed} failed',
                    style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: t.total == 0 ? null : t.fraction,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF2AABEE)),
            ),
          ),
          if (t.currentName != null) ...[
            const SizedBox(height: 8),
            Text(
              t.currentName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: t.canceling ? null : () => ref.read(transferQueueProvider.notifier).cancel(),
              child: Text(t.canceling ? 'Canceling…' : 'Cancel'),
            ),
          ),
        ],
      ),
    );
  }
}
