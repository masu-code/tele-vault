import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../../models/file_item.dart';
import '../../download/providers/download_provider.dart';

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
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(SaveToDeviceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If this widget is recycled for a different file (list reorder/filter),
    // its cached saved-state no longer applies — recheck.
    if (oldWidget.file.id != widget.file.id) {
      setState(() => _saved = false);
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final saved = await LocalFileService.instance.isSaved(widget.file);
    if (mounted) setState(() => _saved = saved);
  }

  @override
  Widget build(BuildContext context) {
    final download = ref.watch(downloadProvider);

    if (download.fileId == widget.file.id) {
      return SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: SizedBox(
            width: 22, height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: download.progress == 0 ? null : download.progress,
            ),
          ),
        ),
      );
    }

    if (_saved) {
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
        await _refresh();
      },
    );
  }
}
