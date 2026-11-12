import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format_utils.dart';
import '../../../core/thumbnail/backfill_service.dart';
import '../../../core/thumbnail/backfill_state.dart';
import '../../../models/file_index.dart';
import '../../explorer/providers/index_provider.dart';

/// One job per app process: it keeps running when the screen is closed
/// (while the app is in the foreground).
final backfillServiceProvider = Provider<BackfillService>(
  (ref) => BackfillService(index: RiverpodBackfillIndex(ref)),
);

/// The job's view of the index: [indexProvider]'s state, written through
/// [IndexNotifier.applyAndSave] (the notifier's own serialized mutation path)
/// once the notifier is idle, so the app state holds the written index.
class RiverpodBackfillIndex implements BackfillIndexAccess {
  RiverpodBackfillIndex(this._ref);

  final Ref _ref;

  static const Duration _idleTimeout = Duration(minutes: 2);

  static bool _usable(IndexState s) =>
      !s.isLoading && !s.isSaving && s.error == null && !s.stale;

  @override
  FileIndex? current() {
    final s = _ref.read(indexProvider);
    return _usable(s) ? s.index : null;
  }

  @override
  Future<FileIndex> write(FileIndex Function(FileIndex current) mutate) async {
    final deadline = DateTime.now().add(_idleTimeout);
    while (!_usable(_ref.read(indexProvider))) {
      if (DateTime.now().isAfter(deadline)) {
        throw const BackfillException('The index stayed busy; run the backfill again later.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // Through the notifier's write chain: the mutation sees the index as it is
    // when its turn comes, so a user mutation queued meanwhile survives.
    return _ref.read(indexProvider.notifier).applyAndSave(mutate);
  }
}

/// Plan / Run / Pause for the thumbnail backfill job (old cloud photos and
/// videos without any thumbnail). Shows counts, bytes and ids only.
class BackfillScreen extends ConsumerStatefulWidget {
  const BackfillScreen({super.key});

  @override
  ConsumerState<BackfillScreen> createState() => _BackfillScreenState();
}

class _BackfillScreenState extends ConsumerState<BackfillScreen> {
  BackfillPlan? _plan;
  BackfillRunResult? _result;
  bool _planning = false;

  BackfillService get _service => ref.read(backfillServiceProvider);

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<BackfillPlan?> _makePlan() async {
    setState(() => _planning = true);
    try {
      final plan = await _service.plan();
      if (mounted) setState(() => _plan = plan);
      return plan;
    } on BackfillBlockedException catch (e) {
      _toast(e.message);
    } catch (_) {
      // The progress card shows the (name-free) error.
    } finally {
      if (mounted) setState(() => _planning = false);
    }
    return null;
  }

  Future<void> _run() async {
    if (_service.requiresUnmeteredNetwork) {
      final plan = await _makePlan();
      if (plan == null || !mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Run thumbnail backfill?'),
          content: Text(
            'About ${humanFileSize(plan.bytesToDownload)} of originals will be '
            'downloaded (${plan.imagesToDownload} images, ${plan.videosToDownload} videos), '
            'plus ${plan.serverThumbs} small thumbnails from Telegram'
            '${plan.packsToInstall > 0 ? ' and ${plan.packsToInstall} thumbnail packs (${humanFileSize(plan.packBytesToInstall)})' : ''}. '
            'Each original is deleted right after its thumbnail is made.\n\n'
            'Wi-Fi or Ethernet is required.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Run')),
          ],
        ),
      );
      if (go != true) return;
    }
    try {
      final result = await _service.run();
      if (mounted) setState(() => _result = result);
    } on BackfillBlockedException catch (e) {
      _toast(e.message);
    } catch (_) {
      // The progress card shows the (name-free) error; the state file lets
      // the next run resume.
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(backfillServiceProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Thumbnail backfill')),
      body: ValueListenableBuilder<BackfillProgress>(
        valueListenable: service.progress,
        builder: (context, progress, _) {
          final busy = progress.running || _planning;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Makes thumbnails for cloud photos and videos that have none, '
                'then uploads them as thumbnail packs so every device gets them '
                'without downloading the originals.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy ? null : _makePlan,
                      child: const Text('Plan'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: busy ? null : _run,
                      child: const Text('Run'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: progress.running ? service.pause : null,
                      child: const Text('Pause'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _ProgressCard(progress: progress, planning: _planning),
              if (_plan != null) ...[
                const SizedBox(height: 12),
                _PlanCard(plan: _plan!),
              ],
              if (_result != null && _result!.failures.isNotEmpty) ...[
                const SizedBox(height: 12),
                _FailuresCard(failures: _result!.failures),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}

Widget _row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: Colors.white70))),
          Text(value),
        ],
      ),
    );

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress, required this.planning});
  final BackfillProgress progress;
  final bool planning;

  String get _phase => switch (progress.phase) {
        BackfillPhase.idle => planning ? 'Planning…' : 'Idle',
        BackfillPhase.planning => 'Planning…',
        BackfillPhase.preparing => 'Preparing…',
        BackfillPhase.serverThumbs => 'Fetching Telegram thumbnails…',
        BackfillPhase.downloading => 'Downloading originals…',
        BackfillPhase.packing => 'Uploading thumbnail packs…',
        BackfillPhase.patching => 'Updating previews…',
        BackfillPhase.paused => 'Paused (Run resumes)',
        BackfillPhase.done => 'Done',
        BackfillPhase.failed => 'Stopped',
      };

  @override
  Widget build(BuildContext context) {
    final total = progress.total;
    return _Card(children: [
      Text(_phase, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: total > 0 ? (progress.processed / total).clamp(0.0, 1.0) : (progress.running ? null : 0),
        backgroundColor: Colors.white12,
      ),
      const SizedBox(height: 8),
      _row('Processed', '${progress.processed} / $total'),
      _row('Thumbnails made', '${progress.produced}'),
      _row('Packs uploaded', '${progress.packsUploaded}'),
      _row('Downloaded so far', humanFileSize(progress.bytesDownloaded)),
      _row('Need a desktop with ffmpeg', '${progress.needsDesktop}'),
      _row('Failures', '${progress.failures}'),
      if (progress.error != null) ...[
        const SizedBox(height: 8),
        Text(progress.error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
      ],
    ]);
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan});
  final BackfillPlan plan;

  @override
  Widget build(BuildContext context) {
    return _Card(children: [
      Text(
        plan.isUpperBound ? 'Plan (upper bound: packs not installed yet)' : 'Plan',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      _row('Photos and videos', '${plan.mediaTotal}'),
      _row('Without any thumbnail', '${plan.candidates}'),
      _row('From Telegram thumbnails', '${plan.serverThumbs}'),
      _row('Images to download', '${plan.imagesToDownload}'),
      _row('Videos to download', '${plan.videosToDownload}'),
      _row('Bytes to download', humanFileSize(plan.bytesToDownload)),
      _row('Need a desktop with ffmpeg', '${plan.needsDesktop}'),
      _row('Missing on Telegram', '${plan.missing}'),
      _row('Waiting for a pack', '${plan.awaitingPack}'),
      _row('Already in packs', '${plan.packed}'),
      _row('Previews to add to the index', '${plan.previewPatches}'),
      _row('Skipped after repeated failures', '${plan.skippedFailures}'),
      if (plan.packsToInstall > 0)
        _row('Packs to install first',
            '${plan.packsToInstall} (${humanFileSize(plan.packBytesToInstall)})'),
      if (plan.candidatesByMime.isNotEmpty) ...[
        const SizedBox(height: 8),
        for (final e in plan.candidatesByMime.entries) _row(e.key, '${e.value}'),
      ],
    ]);
  }
}

class _FailuresCard extends StatelessWidget {
  const _FailuresCard({required this.failures});
  final Map<String, BackfillFailure> failures;

  @override
  Widget build(BuildContext context) {
    final entries = failures.entries.take(100).toList();
    return _Card(children: [
      Text('Failures (${failures.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      for (final e in entries)
        Text(
          '${e.key} · ${e.value.mime} · ${e.value.reason} (x${e.value.attempts})',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
    ]);
  }
}
