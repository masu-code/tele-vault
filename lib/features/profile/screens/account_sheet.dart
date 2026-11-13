import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/format_utils.dart';
import '../../archive/screens/archive_screen.dart';
import '../../auth/providers/auth_provider.dart';
import '../../backup/providers/backup_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../../transfer/widgets/transfer_progress_bar.dart';
import '../providers/maintenance_provider.dart';
import '../providers/profile_provider.dart';
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
            const _MaintenanceStatusLine(),
            const SizedBox(height: 12),
            const _MobileDataToggle(),
            const SizedBox(height: 8),
            const _HeadlessStatus(),
            const SizedBox(height: 12),
            const LogOutButton(),
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

/// Read-only line shown while the automatic maintenance (thumbnail packs,
/// capture dates, thumbnails for old items) is running. Nothing to press:
/// the app finds that work and does it by itself.
class _MaintenanceStatusLine extends ConsumerWidget {
  const _MaintenanceStatusLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(autoMaintenanceProvider);
    return ValueListenableBuilder(
      valueListenable: service.status,
      builder: (context, status, _) {
        if (!status.running) return const SizedBox.shrink();
        final count = status.handled > 0 ? ' (${status.handled})' : '';
        return Padding(
          padding: const EdgeInsets.only(top: 12, left: 4, right: 4),
          child: Text(
            'Optimizando miniaturas y fechas…$count',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        );
      },
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

/// Ends the Telegram session on this device (and server-side, best effort)
/// after a confirmation. See [AuthNotifier.logOut]: the backup stops until the
/// next login, the files in Telegram are not touched.
class LogOutButton extends ConsumerStatefulWidget {
  const LogOutButton({super.key});

  static const title = 'Log out';
  static const confirmTitle = 'Log out of TeleVault?';
  static const confirmBody =
      'Automatic backup stops until you sign in again. Your files in '
      'Telegram are not touched.';

  @override
  ConsumerState<LogOutButton> createState() => _LogOutButtonState();
}

class _LogOutButtonState extends ConsumerState<LogOutButton> {
  bool _busy = false;

  Future<void> _logOut() async {
    // Read before awaiting: this sheet is torn down while the log out runs.
    final auth = ref.read(authProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(LogOutButton.confirmTitle),
        content: const Text(LogOutButton.confirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      // On completion the auth state flips and the app pops back to the
      // login screen (see TeleVaultApp).
      await auth.logOut();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1C1C1E),
      borderRadius: BorderRadius.circular(14),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: _busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.logout, color: Colors.redAccent),
        title: Text(_busy ? 'Logging out…' : LogOutButton.title),
        enabled: !_busy,
        onTap: _logOut,
      ),
    );
  }
}
