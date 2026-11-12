import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/format_utils.dart';
import '../../archive/screens/archive_screen.dart';
import '../../backup/providers/backup_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../../transfer/widgets/transfer_progress_bar.dart';
import '../providers/profile_provider.dart';
import 'backfill_screen.dart';
import 'free_up_storage_screen.dart';

/// Bottom sheet shown when tapping the profile avatar: Telegram account
/// name/phone, device storage usage, and the entry point to free it up.
class AccountSheet extends ConsumerWidget {
  const AccountSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(profileProvider);
    final profile = state.profile;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: const Color(0xFF2AABEE),
                  backgroundImage:
                      profile?.avatar != null ? FileImage(profile!.avatar!) : null,
                  child: profile?.avatar == null
                      ? const Icon(Icons.person, size: 28, color: Colors.white)
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile?.name ?? (state.loading ? 'Loading…' : 'Telegram account'),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      if (profile?.phone != null)
                        Text('+${profile!.phone}',
                            style: const TextStyle(color: Colors.white54))
                      else if (state.failed)
                        GestureDetector(
                          onTap: () => ref.read(profileProvider.notifier).load(),
                          child: const Text('Could not load account — tap to retry',
                              style: TextStyle(color: Color(0xFF2AABEE), fontSize: 13)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const TransferProgressBar(),
            const SizedBox(height: 12),
            const _StorageCard(),
            const SizedBox(height: 12),
            _ArchivedButton(),
            const SizedBox(height: 12),
            const _BackfillButton(),
            const SizedBox(height: 12),
            const _MobileDataToggle(),
            const SizedBox(height: 8),
            const _HeadlessStatus(),
          ],
        ),
      ),
    );
  }
}

class _StorageCard extends StatefulWidget {
  const _StorageCard();

  @override
  State<_StorageCard> createState() => _StorageCardState();
}

class _StorageCardState extends State<_StorageCard> {
  double? _freeMb;
  double? _totalMb;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final disk = DiskSpacePlus();
    final free = await disk.getFreeDiskSpace;
    final total = await disk.getTotalDiskSpace;
    if (mounted) setState(() { _freeMb = free; _totalMb = total; });
  }

  @override
  Widget build(BuildContext context) {
    final free = _freeMb;
    final total = _totalMb;
    final used = (free != null && total != null) ? total - free : null;
    final fraction = (used != null && total != null && total > 0) ? used / total : null;

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
              const Icon(Icons.smartphone, size: 18, color: Color(0xFF2AABEE)),
              const SizedBox(width: 8),
              Text(
                fraction != null
                    ? '${(fraction * 100).round()}% of device storage in use'
                    : 'Device storage',
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: fraction,
            backgroundColor: Colors.white12,
            valueColor: const AlwaysStoppedAnimation(Color(0xFF2AABEE)),
          ),
          const SizedBox(height: 8),
          Text(
            used != null && total != null
                ? '${humanFileSize((used * 1024 * 1024).round())} of ${humanFileSize((total * 1024 * 1024).round())} used'
                : 'Calculating…',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FreeUpStorageScreen()),
                );
              },
              child: const Text('Free up space'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Entry point to [ArchiveScreen] — archived photos/videos are hidden from
/// Gallery/Albums but not deleted (see [FileIndex.archivedMediaFiles]).
class _ArchivedButton extends ConsumerWidget {
  const _ArchivedButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      indexProvider.select((s) => s.index.archivedMediaFiles.length),
    );
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: const Icon(Icons.archive_outlined, color: Color(0xFF2AABEE)),
        title: const Text('Archived'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (count > 0)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text('$count', style: const TextStyle(color: Colors.white54)),
              ),
            const Icon(Icons.chevron_right, color: Colors.white38),
          ],
        ),
        onTap: () {
          Navigator.pop(context);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ArchiveScreen()),
          );
        },
      ),
    );
  }
}

/// Entry point to [BackfillScreen] (thumbnails for old cloud items).
class _BackfillButton extends StatelessWidget {
  const _BackfillButton();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: const Icon(Icons.photo_library_outlined, color: Color(0xFF2AABEE)),
        title: const Text('Thumbnail backfill'),
        trailing: const Icon(Icons.chevron_right, color: Colors.white38),
        onTap: () {
          Navigator.pop(context);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const BackfillScreen()),
          );
        },
      ),
    );
  }
}

/// When the background (app-closed) backup task last ran and what it did.
/// A missing or old timestamp means Android/MIUI isn't running the task at all
/// (battery restrictions / autostart); a recent one with a skip reason says
/// exactly why nothing was uploaded.
class _HeadlessStatus extends StatelessWidget {
  const _HeadlessStatus();

  Future<({DateTime at, String status})?> _load() async {
    final registry = BackupRegistry.instance;
    await registry.init();
    await registry.reload();
    return registry.lastHeadlessRun;
  }

  String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 48) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _load(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SizedBox.shrink();
        final run = snap.data;
        final text = run == null
            ? 'Background backup has never run (check Autostart and battery '
                '"No restrictions" for TeleVault in system settings)'
            : 'Background backup ran ${_ago(run.at)}: ${run.status}';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        );
      },
    );
  }
}

/// Lets the user opt in to running automatic backup (album auto-sync, and
/// picking up new photos as they arrive) over mobile data — off by default,
/// so it only runs on WiFi unless explicitly allowed here. Doesn't affect
/// explicit actions like Gallery's own "Upload" button.
class _MobileDataToggle extends ConsumerWidget {
  const _MobileDataToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = ref.watch(backupProvider).allowMobileData;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.signal_cellular_alt, size: 18, color: Color(0xFF2AABEE)),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Auto-backup with mobile data', style: TextStyle(fontSize: 14)),
          ),
          Switch(
            value: allowed,
            onChanged: (v) => ref.read(backupProvider.notifier).setAllowMobileData(v),
          ),
        ],
      ),
    );
  }
}
