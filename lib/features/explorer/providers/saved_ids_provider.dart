import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../../models/file_item.dart';

/// Ids of cloud files known to be saved on this device, for the Files list's
/// per-row "on device" indicator.
///
/// Rows used to each run their own disk check at build and again on every
/// device-state bump. Now a row only [register]s itself (one check the first
/// time its id is seen) and the list refreshes all live rows together through
/// [refreshAlive], publishing a single state change at the end.
///
/// State holds only the positives: a row selects `contains(id)`, so it
/// rebuilds only when its own flag flips.
class SavedIdsNotifier extends StateNotifier<Set<String>> {
  SavedIdsNotifier() : super(const <String>{});

  /// Rows currently mounted, by file id.
  final Map<String, FileItem> _alive = {};

  /// Ids whose flag has been checked since the last [refreshAlive].
  final Set<String> _checked = {};

  /// A row came on screen. Checks the disk once unless already known.
  void register(FileItem file) {
    _alive[file.id] = file;
    if (_checked.add(file.id)) _check([file]);
  }

  void unregister(String fileId) => _alive.remove(fileId);

  /// Re-checks one file (e.g. right after saving it).
  Future<void> recheck(FileItem file) => _check([file]);

  /// Something elsewhere in the app saved or deleted a file: drop what is
  /// known about rows that are not on screen and re-check the ones that are,
  /// in one batch.
  Future<void> refreshAlive() {
    _checked
      ..clear()
      ..addAll(_alive.keys);
    final stale = state.where((id) => !_alive.containsKey(id)).toList();
    if (stale.isNotEmpty) state = {...state}..removeAll(stale);
    return _check(_alive.values.toList());
  }

  Future<void> _check(List<FileItem> files) async {
    final results = await Future.wait(
      files.map((f) async {
        try {
          return await LocalFileService.instance.isSaved(f);
        } catch (_) {
          return false;
        }
      }),
    );
    if (!mounted) return;
    Set<String>? next;
    for (var i = 0; i < files.length; i++) {
      final id = files[i].id;
      final saved = results[i];
      if (saved == (next ?? state).contains(id)) continue;
      next ??= {...state};
      saved ? next.add(id) : next.remove(id);
    }
    if (next != null) state = next;
  }
}

final savedIdsProvider =
    StateNotifierProvider<SavedIdsNotifier, Set<String>>((ref) => SavedIdsNotifier());
