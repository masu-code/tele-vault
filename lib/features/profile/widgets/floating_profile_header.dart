import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../transfer/providers/transfer_queue_provider.dart';
import '../providers/profile_provider.dart';
import '../screens/account_sheet.dart';

/// A transparent header that floats over the screen's content (Google
/// Photos-style) instead of a solid AppBar — content scrolls behind it. Used
/// on the default (non-selecting) state of Gallery, Albums, and Files; each
/// screen keeps its own solid AppBar for selection mode.
class FloatingProfileHeader extends ConsumerWidget {
  const FloatingProfileHeader({
    super.key,
    required this.title,
    this.onBack,
    this.actions = const [],
  });

  final String title;
  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).profile;
    // Only re-reads when active flips true/false, not on every per-item
    // progress tick — drives the small spinning badge on the avatar. Full
    // progress detail lives in AccountSheet, opened by tapping that avatar.
    final isTransferring = ref.watch(transferQueueProvider.select((s) => s.active));
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black45, Colors.transparent],
          ),
        ),
        child: SizedBox(
          height: kToolbarHeight,
          child: Row(
            children: [
              if (onBack != null)
                IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack)
              else
                const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ...actions,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: GestureDetector(
                  onTap: () {
                    // A no-op if already loaded/loading; retries if the
                    // initial fetch at app start failed silently.
                    ref.read(profileProvider.notifier).load();
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => const AccountSheet(),
                    );
                  },
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: const Color(0xFF2AABEE),
                        backgroundImage: profile?.avatar != null
                            ? FileImage(profile!.avatar!)
                            : null,
                        child: profile?.avatar == null
                            ? const Icon(Icons.person, size: 18, color: Colors.white)
                            : null,
                      ),
                      // Subtle hint that a background sync is running — tap
                      // the avatar for the actual progress (see AccountSheet).
                      if (isTransferring)
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Color(0xFF1C1C1E),
                              shape: BoxShape.circle,
                            ),
                            child: const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(Color(0xFF2AABEE)),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
