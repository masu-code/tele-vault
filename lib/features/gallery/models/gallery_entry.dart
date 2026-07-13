import 'package:photo_manager/photo_manager.dart';
import '../../../models/file_item.dart';

/// One row in the unified Gallery timeline: a device asset, a cloud
/// [FileItem], or both (when the same photo/video is on-device AND already
/// uploaded). At least one of [asset]/[fileItem] is always non-null.
class GalleryEntry {
  const GalleryEntry({this.asset, this.fileItem})
      : assert(asset != null || fileItem != null);

  final AssetEntity? asset;
  final FileItem? fileItem;

  /// Stable identity for selection sets and widget keys.
  String get key => asset?.id ?? fileItem!.id;

  bool get isUploaded => fileItem != null;
  bool get isOnDevice => asset != null;

  bool get isVideo => fileItem != null
      ? fileItem!.mimeType.startsWith('video/')
      : asset!.type == AssetType.video;

  /// The date used for sorting/grouping. When a device asset is present this
  /// is the real capture date; otherwise it falls back to [FileItem.createdAt]
  /// which — for every current upload path — is actually the *upload* time,
  /// not the photo's original date. Cloud-only entries (uploaded from a PC,
  /// or whose device copy was later deleted) therefore land in whichever
  /// month they were added to the vault, not necessarily when they were
  /// taken. This asymmetry is a known, accepted limitation.
  DateTime get effectiveDate => asset?.createDateTime ?? fileItem!.createdAt;
}

/// One month section of the timeline, newest first.
class GalleryMonthGroup {
  const GalleryMonthGroup({required this.month, required this.entries});

  /// Normalized to the 1st of the month, local time.
  final DateTime month;
  final List<GalleryEntry> entries;
}

/// Buckets [sorted] (must already be sorted by [GalleryEntry.effectiveDate]
/// descending) into month sections in a single pass.
List<GalleryMonthGroup> groupEntriesByMonth(List<GalleryEntry> sorted) {
  final groups = <GalleryMonthGroup>[];
  DateTime? currentMonth;
  List<GalleryEntry>? currentEntries;

  for (final entry in sorted) {
    final local = entry.effectiveDate.toLocal();
    final month = DateTime(local.year, local.month);
    if (currentMonth != month) {
      currentMonth = month;
      currentEntries = [];
      groups.add(GalleryMonthGroup(month: month, entries: currentEntries));
    }
    currentEntries!.add(entry);
  }
  return groups;
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "October 2026" — English, matching the rest of the app's UI.
String monthLabel(DateTime month) => '${_monthNames[month.month - 1]} ${month.year}';
