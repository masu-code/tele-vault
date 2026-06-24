import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../../models/file_item.dart';
import '../../download/providers/download_provider.dart';

/// Trailing action for a file row:
/// - not saved on the device → a download icon that saves it;
/// - already saved → a device icon that reveals it in the OS file explorer;
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
      final deviceIcon =
          (Platform.isAndroid || Platform.isIOS) ? Icons.smartphone : Icons.computer;
      return IconButton(
        icon: Icon(deviceIcon, color: const Color(0xFF2AABEE)),
        tooltip: 'Saved on device — show location',
        onPressed: () => ref.read(downloadProvider.notifier).revealOnDevice(widget.file),
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
