import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bumped whenever any action changes a file's on-device or backed-up-to-
/// Telegram status: upload, save-to-device, or delete (from either side).
///
/// Device/cloud presence is checked in several independent places (the
/// viewer's action row, album grids, selection bars) and each one caches its
/// answer for the current build. Without a shared invalidation signal, an
/// action in one place (e.g. deleting from the viewer) leaves every other
/// place showing stale state until the screen is torn down and rebuilt from
/// scratch. Anything that displays on-device/uploaded state should
/// `ref.watch(deviceStateVersion)` so it recomputes on every bump instead.
final deviceStateVersion = StateProvider<int>((ref) => 0);

// Accepts both `Ref` (StateNotifiers/providers) and `WidgetRef` (widgets) —
// they're unrelated types in this Riverpod version, but both expose a
// compatible `read()`.
void bumpDeviceState(dynamic ref) => ref.read(deviceStateVersion.notifier).state++;
