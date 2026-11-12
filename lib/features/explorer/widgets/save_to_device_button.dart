import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/file_item.dart';
import '../../download/providers/download_provider.dart';
import '../providers/saved_ids_provider.dart';

/// Icon used everywhere to mean "already on this device" (Gallery, Albums,
/// Files) — kept as one constant so the indicator stays visually consistent.
IconData onDeviceIcon() =>
    (Platform.isAndroid || Platform.isIOS) ? Icons.smartphone : Icons.computer;

/// Trailing action for a file row:
/// - not saved on the device → a download icon that saves it;
/// - already saved → a plain "on device" indicator;
/// - while saving → a progress spinner.
class SaveToDeviceButton extends ConsumerStatefulWidget {
  const SaveToDeviceButton({super.key, required this.file});

  final FileItem file;

  @override
  ConsumerState<SaveToDeviceButton> createState() => _SaveToDeviceButtonState();
}

class _SaveToDeviceButtonState extends ConsumerState<SaveToDeviceButton> {
  late final SavedIdsNotifier _saved;

  @override
  void initState() {
    super.initState();
    _saved = ref.read(savedIdsProvider.notifier);
    _saved.register(widget.file);
  }

  @override
  void didUpdateWidget(SaveToDeviceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If this widget is recycled for a different file (list reorder/filter),
    // its saved-state no longer applies — register the new one.
    if (oldWidget.file.id != widget.file.id) {
      _saved.unregister(oldWidget.file.id);
      _saved.register(widget.file);
    }
  }

  @override
  void dispose() {
    _saved.unregister(widget.file.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.file.id;
    // Narrow watches: only the row being downloaded rebuilds on progress, and
    // a row only rebuilds when its own saved flag flips. Staleness after a
    // delete/save elsewhere is handled by the list-level listener in
    // ExplorerScreen (see SavedIdsNotifier.refreshAlive).
    final downloadProgress = ref.watch(
      downloadProvider.select((d) => d.fileId == id ? d.progress : null),
    );
    final saved = ref.watch(savedIdsProvider.select((s) => s.contains(id)));

    if (downloadProgress != null) {
      return SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: SizedBox(
            width: 22, height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: downloadProgress == 0 ? null : downloadProgress,
            ),
          ),
        ),
      );
    }

    if (saved) {
      return SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: Icon(onDeviceIcon(), color: const Color(0xFF2AABEE)),
        ),
      );
    }

    return IconButton(
      icon: const Icon(Icons.download_outlined),
      tooltip: 'Save to device',
      onPressed: () async {
        await ref.read(downloadProvider.notifier).saveToDevice(widget.file);
        await _saved.recheck(widget.file);
      },
    );
  }
}
