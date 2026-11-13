import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/telegram/profile_service.dart';

class ProfileState {
  final TelegramProfile? profile;
  final bool loading;

  /// Set when the last fetch attempt failed, so callers can offer a retry
  /// instead of silently showing a blank avatar forever. Cleared as soon as
  /// a new attempt starts.
  final bool failed;

  const ProfileState({this.profile, this.loading = false, this.failed = false});
}

/// Loads the logged-in Telegram account's name/phone/avatar once and shares
/// it across every tab (Gallery, Albums, Files), instead of each screen
/// fetching it independently.
class ProfileNotifier extends StateNotifier<ProfileState> {
  ProfileNotifier() : super(const ProfileState());

  /// Bumped by [reset]: a fetch that finishes after a log out belongs to the
  /// previous account and is dropped.
  int _epoch = 0;

  /// Log out: forgets the loaded account so the next login does not show the
  /// previous one's name, phone and avatar.
  void reset() {
    _epoch++;
    if (mounted) state = const ProfileState();
  }

  /// [load] is a no-op once a profile is cached, so it's safe to call
  /// unconditionally on every entry point (app start, opening the account
  /// sheet) — a prior failure leaves profile null, which lets this retry.
  Future<void> load() async {
    if (state.profile != null || state.loading) return;
    final epoch = _epoch;
    state = const ProfileState(loading: true);
    try {
      final profile = await ProfileService.instance.fetchProfile();
      if (epoch != _epoch || !mounted) return;
      state = ProfileState(profile: profile);
    } catch (_) {
      if (epoch != _epoch || !mounted) return;
      state = const ProfileState(failed: true);
    }
  }
}

final profileProvider =
    StateNotifierProvider<ProfileNotifier, ProfileState>((_) => ProfileNotifier());
