import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/backup/asset_upload_service.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../core/download/download_service.dart';
import '../../../core/download/download_worker.dart' show withInactivityTimeout;
import '../../../core/format_utils.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../../core/thumbnail/thumbnail_service.dart';
import '../../../models/file_item.dart';
import '../../backup/providers/backup_provider.dart';
import '../../download/providers/download_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../../gallery/models/gallery_entry.dart';
import '../video_controls.dart';
import 'add_to_album_sheet.dart';
import 'delete_source_dialog.dart';
import 'photo_zoom_controller.dart';
import 'viewer_page_chrome.dart';

/// The page widgets and their action/info builders for both viewer kinds
/// (cloud [FileItem] and local device [AssetEntity]) — kept together, rather
/// than split back into their two screen files, because they're tightly
/// coupled (each page widget calls its matching *MediaActions/*MediaInfo
/// helper directly) and a mixed-type viewer (`MixedMediaViewerScreen`) needs
/// to reuse all four page widgets unchanged.

/// Lets a PageView be dragged with a mouse (desktop), not just touch. Shared
/// by every full-screen viewer screen.
class DragScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

/// How far a double tap on a video's left/right edge jumps.
const _seekStep = Duration(seconds: 5);

/// Longest a cloud file may go without a progress tick before the viewer gives
/// up and offers Retry. [DownloadService.downloadToCache] has its own, shorter
/// guard; this one also covers the stretch where the call is joined to another
/// caller's in-flight download (whose progress it never sees).
const _viewerLoadTimeout = Duration(seconds: 90);

/// Longest `Player.open` may take before the video page shows its error state.
const _videoOpenTimeout = Duration(seconds: 20);

/// How long the first frame may take with the forced `mediacodec` decoder
/// before the page falls back to mpv's `auto-safe` and reopens.
const _firstFrameTimeout = Duration(seconds: 5);

/// A neighbour's file is only decoded ahead of time when it is at most this
/// big: a huge original costs more to decode early than the swipe saves.
const _precacheMaxBytes = 8 * 1024 * 1024;

/// Decode width for a full-screen photo, in physical pixels.
///
/// Without a cap the viewer decoded every photo at its native resolution: a
/// 12MP phone photo is ~48MB of uncompressed pixels, and a PageView holds the
/// current page plus its neighbours, so swiping meant tens of megabytes
/// allocated and a full-resolution decode landing in the middle of the swipe.
///
/// The fitted view decodes at 1x the screen's pixel width. Once the user zooms
/// past [PhotoZoomController]'s `highRes` threshold the page swaps to
/// [highRes] (2x) so the zoomed detail stays sharp; the 2x decode (~25MB) is
/// only paid by a photo that is actually being inspected.
int photoDecodeWidth(BuildContext context, {bool highRes = false}) {
  final width = MediaQuery.sizeOf(context).width;
  final dpr = MediaQuery.devicePixelRatioOf(context);
  return (width * dpr * (highRes ? 2 : 1)).round();
}

/// Resolves the same local [File] the photo pages themselves would show for
/// [entry] — device copy first, cloud cache download otherwise — without any
/// of the progress/error UI state those pages carry.
Future<File?> _resolveEntryFile(GalleryEntry entry) async {
  final asset = entry.asset;
  if (asset != null) {
    final f = await asset.file;
    if (f != null) return f;
  }
  // Precaching must never start a Telegram download: the neighbour page
  // already downloads its own photo, and a second copy of the same download
  // (every byte AES-decrypted on the main isolate) is what starved the UI.
  // Only a copy that's already on disk is worth warming here.
  final fileItem = entry.fileItem;
  if (fileItem != null) return DownloadService.instance.cachedFileFor(fileItem);
  return null;
}

/// Decodes [entry]'s photo into Flutter's image cache ahead of time, at the
/// exact same [ResizeImage] configuration [CloudImagePage]/[LocalImagePage]
/// build with (`Image(..., cacheWidth: photoDecodeWidth(context))` resolves
/// to this same provider internally) — so when the PageView actually reveals
/// the page, the frame is already sitting in the cache instead of being
/// decoded live during the swipe.
///
/// The screens call this for the forward neighbour only (one extra decode
/// instead of two), and it skips originals over [_precacheMaxBytes].
/// No-ops for videos — nothing here helps `media_kit`'s decode pipeline.
Future<void> precacheGalleryEntry(BuildContext context, GalleryEntry entry) async {
  if (entry.isVideo) return;
  try {
    final file = await _resolveEntryFile(entry);
    if (file == null || !context.mounted) return;
    if (await file.length() > _precacheMaxBytes) return;
    if (!context.mounted) return;
    await precacheImage(
      ResizeImage(FileImage(file), width: photoDecodeWidth(context)),
      context,
    );
  } catch (_) {
    // Best-effort — the page's own load path still runs and shows its own
    // error state if the file is genuinely unreachable.
  }
}

// ---------------------------------------------------------------------------
// Video player construction (one seam, so tests can prove a page that never
// loads never creates a libmpv player).
// ---------------------------------------------------------------------------

typedef ViewerPlayerFactory = Player Function();

// 8 MiB demuxer buffer instead of media_kit's 32 MiB default: the viewer plays
// local files (device original or the cache copy), so a deep read-ahead buys
// nothing and each live player holds it.
Player _defaultPlayerFactory() =>
    Player(configuration: const PlayerConfiguration(bufferSize: 8 * 1024 * 1024));

/// Creates the viewer's video players. Replaced only by tests.
@visibleForTesting
ViewerPlayerFactory debugPlayerFactory = _defaultPlayerFactory;

// Android: pin the MediaCodec decoder (media_kit's default is `auto-safe`) and
// attach the surface once the video size is known. Other platforms keep the
// defaults. [_VideoSession] falls back to `auto-safe` if no frame arrives.
VideoController _createVideoController(Player player) => VideoController(
  player,
  configuration: Platform.isAndroid
      ? const VideoControllerConfiguration(
          hwdec: 'mediacodec',
          androidAttachSurfaceAfterVideoParameters: true,
        )
      : const VideoControllerConfiguration(),
);

/// A [Player] + [VideoController] pair created lazily by a video page's
/// `_load`, plus the open/diagnostics/fallback logic shared by the cloud and
/// local video pages.
class _VideoSession {
  _VideoSession() : player = debugPlayerFactory() {
    controller = _createVideoController(player);
  }

  final Player player;
  late final VideoController controller;
  bool _disposed = false;

  /// Opens [file] paused. Throws on failure or after [_videoOpenTimeout].
  Future<void> open(File file) =>
      player.open(Media(file.path), play: false).timeout(_videoOpenTimeout);

  /// After a successful [open]: logs which decoder mpv picked (no path) and,
  /// on Android, reopens with `auto-safe` if mediacodec produced no frame.
  Future<void> watchFirstFrame(File file, {required bool Function() shouldPlay}) async {
    if (_disposed) return;
    await _logHwdec();
    if (!Platform.isAndroid) return;
    try {
      await controller.waitUntilFirstFrameRendered.timeout(_firstFrameTimeout);
    } on TimeoutException {
      if (_disposed) return;
      debugPrint('TVDIAG: video no first frame in ${_firstFrameTimeout.inSeconds}s, hwdec fallback auto-safe');
      try {
        final native = player.platform;
        if (native is NativePlayer) await native.setProperty('hwdec', 'auto-safe');
        final position = player.state.position;
        await open(file);
        if (_disposed) return;
        if (position > Duration.zero) await player.seek(position);
        if (shouldPlay()) await player.play();
        await _logHwdec();
      } catch (_) {
        // The page stays on its current state; nothing more to try.
      }
    } catch (_) {
      // Controller creation failed or the player is gone: nothing to watch.
    }
  }

  Future<void> _logHwdec() async {
    try {
      final native = player.platform;
      if (native is! NativePlayer || _disposed) return;
      final value = await native.getProperty('hwdec-current');
      debugPrint('TVDIAG: video hwdec=${value.isEmpty ? 'none' : value}');
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await player.dispose();
  }
}

/// Seeks [player] by [delta], clamped to the clip's bounds. Shared by both
/// video pages' double-tap handlers.
void _seekBy(Player player, Duration delta) {
  final target = player.state.position + delta;
  final duration = player.state.duration;
  player.seek(
    target < Duration.zero
        ? Duration.zero
        : (duration > Duration.zero && target > duration ? duration : target),
  );
}

/// The gallery's thumbnail (on disk or in memory from the grid the user
/// tapped) scaled up to fill the page, or null when there is none. Shown under
/// the loading ring, under an error, and while the full-resolution frame is
/// still decoding, so a page with a thumbnail is never spinner-only.
Widget? _thumbPreview({File? cloudThumb, Uint8List? localThumb}) {
  Widget fill(Widget image) => SizedBox.expand(child: image);
  if (cloudThumb != null) {
    return fill(
      Image.file(
        cloudThumb,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
  if (localThumb != null) {
    return fill(Image.memory(localThumb, fit: BoxFit.contain, gaplessPlayback: true));
  }
  return null;
}

Widget _progressRing(double value) => SizedBox(
  width: 28,
  height: 28,
  child: CircularProgressIndicator(
    strokeWidth: 2.5,
    value: value == 0 ? null : value,
  ),
);

/// What a page shows while its full-resolution file is still loading: the
/// thumbnail scaled up with a small progress ring on top — like every gallery
/// app, rather than a black screen with a spinner until the whole file arrives.
///
/// [progress] is a notifier, not a value: only the ring rebuilds per tick,
/// not the page (and, through the page's descriptor report, the chrome host).
Widget _loadingPreview({
  File? cloudThumb,
  Uint8List? localThumb,
  ValueListenable<double>? progress,
}) {
  final ring = progress == null
      ? _progressRing(0)
      : ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, value, _) => _progressRing(value),
        );
  final preview = _thumbPreview(cloudThumb: cloudThumb, localThumb: localThumb);
  if (preview == null) return Center(child: ring);
  return Stack(
    fit: StackFit.expand,
    children: [
      preview,
      Align(alignment: const Alignment(0, 0.85), child: ring),
    ],
  );
}

/// Short, generic failure state with a Retry button. Never shows the
/// exception text (it can carry paths or Telegram internals); the thumbnail,
/// when there is one, stays visible behind it.
Widget _errorView({
  required String message,
  required VoidCallback onRetry,
  File? cloudThumb,
  Uint8List? localThumb,
}) {
  final panel = Center(
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
  final preview = _thumbPreview(cloudThumb: cloudThumb, localThumb: localThumb);
  if (preview == null) return panel;
  return Stack(fit: StackFit.expand, children: [preview, panel]);
}

/// The zoomable full-resolution photo shared by the cloud and local image
/// pages. Decoded at 1x screen pixels, or 2x once [highRes] (the zoom passed
/// its threshold). [placeholder] (the thumbnail) stays up until the first
/// full-resolution frame is ready; after that it never comes back: changing
/// `cacheWidth` resets Flutter's frame number to null, so without the
/// `_shownFullRes` flag every pinch past the threshold flashed the blurry
/// thumbnail again for the 200-500 ms the new decode took. `gaplessPlayback`
/// keeps the previous frame on screen across the 1x -> 2x swap.
Widget _zoomableImage(
  BuildContext context, {
  required File file,
  required PhotoZoomController zoom,
  required bool highRes,
  Widget? placeholder,
}) {
  return _ZoomableImage(
    file: file,
    zoom: zoom,
    highRes: highRes,
    placeholder: placeholder,
  );
}

class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({
    required this.file,
    required this.zoom,
    required this.highRes,
    this.placeholder,
  });
  final File file;
  final PhotoZoomController zoom;
  final bool highRes;
  final Widget? placeholder;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  /// True once any full-resolution frame of [_ZoomableImage.file] has arrived.
  bool _shownFullRes = false;

  @override
  void didUpdateWidget(_ZoomableImage old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path) _shownFullRes = false;
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.placeholder;
    return InteractiveViewer(
      transformationController: widget.zoom.transform,
      minScale: 1,
      maxScale: 5,
      child: Center(
        child: Image.file(
          widget.file,
          cacheWidth: photoDecodeWidth(context, highRes: widget.highRes),
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          frameBuilder: placeholder == null
              ? null
              : (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) {
                    _shownFullRes = true;
                    return child;
                  }
                  return _shownFullRes ? child : placeholder;
                },
          errorBuilder: (_, _, _) => const Text(
            'Could not display image.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cloud pages — a FileItem stored in the Telegram-backed vault.
// ---------------------------------------------------------------------------

class CloudImagePage extends ConsumerStatefulWidget {
  const CloudImagePage({
    super.key,
    required this.file,
    required this.pageIndex,
    required this.onDescriptor,
    this.zoomLock,
    this.localAsset,
  });
  final FileItem file;

  /// This page's position in the viewer's PageView — see [onDescriptor].
  final int pageIndex;

  /// Reports this page's actions/info/zoom up to the screen's
  /// [ViewerChromeHost], called on every build; the screen only actually
  /// uses it when [pageIndex] is the currently-showing page. See
  /// [ViewerChromeDescriptor] and the class doc on [ViewerChromeHost].
  final void Function(int pageIndex, ViewerChromeDescriptor descriptor)
  onDescriptor;

  /// The enclosing viewer screen's PageView freeze flag. See [ViewerZoomLock].
  final ViewerZoomLock? zoomLock;

  /// The same photo's copy on this device, when there is one.
  ///
  /// A photo that is both on-device and uploaded is shown through this page
  /// rather than [LocalImagePage] because the cloud page carries the richer
  /// action row (delete from Telegram, add to album). That is worth keeping —
  /// but it used to mean the pixels came from Telegram too, so opening or
  /// swiping past a photo already sitting on the phone's own storage paid for
  /// a network download first. Reading the local file instead makes it
  /// instant and leaves the actions untouched.
  final AssetEntity? localAsset;

  @override
  ConsumerState<CloudImagePage> createState() => _CloudImagePageState();
}

class _CloudImagePageState extends ConsumerState<CloudImagePage>
    with SingleTickerProviderStateMixin {
  // A notifier, not a setState field: a progress tick must repaint only the
  // ring, not rebuild the page (and, through the descriptor report in build,
  // the chrome host and the providers the actions watch).
  final ValueNotifier<double> _progress = ValueNotifier(0);
  File? _local;
  bool _failed = false;

  // Owns the transform, the "is zoomed" flag and the double-tap zoom
  // animation. The flag has two jobs: InteractiveViewer's own pan/scale
  // recognizer competes with the screen-level ViewerChromeHost's own
  // gestures for the same pointer once zoomed in, and the enclosing PageView
  // has to stop treating a horizontal pan as "next photo".
  late final PhotoZoomController _zoom = PhotoZoomController(this);

  void _reportZoom() => widget.zoomLock?.report(_zoom.zoomed.value);

  // Fires only when the zoom crosses the 1x <-> 2x decode threshold.
  void _onHighResChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _zoom.zoomed.addListener(_reportZoom);
    _zoom.highRes.addListener(_onHighResChanged);
    _load();
  }

  Future<File> _fetchFromCloud() => withInactivityTimeout<File>(
    _viewerLoadTimeout,
    (touch) => DownloadService.instance.downloadToCache(
      widget.file,
      onProgress: (p) {
        touch();
        if (mounted) _progress.value = p;
      },
    ),
  );

  Future<void> _load() async {
    final asset = widget.localAsset;
    try {
      var file = asset != null ? await asset.file : await _fetchFromCloud();
      if (!mounted) return;
      // The device copy vanished between the gallery listing this entry and
      // opening it (deleted, SD card pulled, …) — fall back to the vault's
      // copy rather than failing outright.
      file ??= await _fetchFromCloud();
      if (!mounted) return;
      setState(() => _local = file);
    } catch (e) {
      debugPrint('TVDIAG: viewer cloud image load failed (${e.runtimeType})');
      if (mounted) setState(() => _failed = true);
    }
  }

  void _retry() {
    setState(() => _failed = false);
    _progress.value = 0;
    _load();
  }

  @override
  void dispose() {
    _zoom.zoomed.removeListener(_reportZoom);
    _zoom.highRes.removeListener(_onHighResChanged);
    // Release the screen's PageView freeze — a page can still be torn down
    // while zoomed (keyboard ←/→, the route popping), and leaving the lock
    // latched would freeze paging for whatever page comes next.
    widget.zoomLock?.report(false);
    _zoom.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Actions/info depend only on widget.file, not on load state. Progress
    // no longer rebuilds this page, so this runs on load-state, zoom-decode
    // and provider changes only; the host only actually uses the report once
    // widget.pageIndex is current anyway.
    widget.onDescriptor(
      widget.pageIndex,
      ViewerChromeDescriptor(
        actions: cloudMediaActions(context, ref, widget.file),
        infoBuilder: (context) => cloudMediaInfo(widget.file),
        onDoubleTapZoom: _zoom.toggleZoom,
        zoomed: _zoom.zoomed,
      ),
    );

    final cloudThumb = ThumbnailService.instance.cachedCloud(widget.file.id);
    final localThumb = widget.localAsset == null
        ? null
        : ThumbnailService.instance.cachedLocal(widget.localAsset!.id);

    if (_failed) {
      return _errorView(
        message: 'Could not load this photo.',
        onRetry: _retry,
        cloudThumb: cloudThumb,
        localThumb: localThumb,
      );
    }
    final local = _local;
    if (local == null) {
      return _loadingPreview(
        cloudThumb: cloudThumb,
        localThumb: localThumb,
        progress: _progress,
      );
    }
    return _zoomableImage(
      context,
      file: local,
      zoom: _zoom,
      highRes: _zoom.highRes.value,
      placeholder: _thumbPreview(cloudThumb: cloudThumb, localThumb: localThumb),
    );
  }
}

class CloudVideoPage extends ConsumerStatefulWidget {
  const CloudVideoPage({
    super.key,
    required this.file,
    required this.pageIndex,
    required this.onDescriptor,
    required this.isCurrent,
    this.localAsset,
  });
  final FileItem file;

  /// See [CloudImagePage.pageIndex]/[CloudImagePage.onDescriptor].
  final int pageIndex;
  final void Function(int pageIndex, ViewerChromeDescriptor descriptor)
  onDescriptor;

  /// Whether this is the page on screen. The PageView keeps neighbours built
  /// (allowImplicitScrolling), so without this a neighbouring video loaded and
  /// played its audio under the photo being viewed. Only the current page loads
  /// and plays; leaving it pauses.
  final bool isCurrent;

  /// The same video's copy on this device — see [CloudImagePage.localAsset].
  /// It matters even more here: re-downloading a video from Telegram just to
  /// play the one already on the phone can mean tens of megabytes and a long
  /// wait before the first frame.
  final AssetEntity? localAsset;

  @override
  ConsumerState<CloudVideoPage> createState() => _CloudVideoPageState();
}

class _CloudVideoPageState extends ConsumerState<CloudVideoPage> {
  // Created in _load, never before: the PageView keeps neighbours built, and
  // a page that never becomes current must not spin up a libmpv player just
  // to throw it away in dispose().
  _VideoSession? _session;
  final ValueNotifier<double> _progress = ValueNotifier(0);
  bool _ready = false;
  bool _started = false;
  bool _opened = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.isCurrent) _load();
  }

  @override
  void didUpdateWidget(CloudVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isCurrent == widget.isCurrent) return;
    if (widget.isCurrent) {
      if (!_started) {
        _load();
      } else if (_opened) {
        _session?.player.play();
      }
    } else if (_opened) {
      _session?.player.pause();
    }
  }

  Future<void> _load() async {
    _started = true;
    try {
      final file =
          await widget.localAsset?.file ??
          await withInactivityTimeout<File>(
            _viewerLoadTimeout,
            (touch) => DownloadService.instance.downloadToCache(
              widget.file,
              onProgress: (p) {
                touch();
                if (mounted) _progress.value = p;
              },
            ),
          );
      if (!mounted) return;
      final session = _session ??= _VideoSession();
      await session.open(file);
      if (!mounted) return;
      _opened = true;
      if (widget.isCurrent) session.player.play();
      setState(() => _ready = true);
      unawaited(
        session.watchFirstFrame(file, shouldPlay: () => mounted && widget.isCurrent),
      );
    } catch (e) {
      debugPrint('TVDIAG: viewer cloud video load failed (${e.runtimeType})');
      if (mounted) setState(() => _failed = true);
    }
  }

  void _retry() {
    setState(() => _failed = false);
    _progress.value = 0;
    _load();
  }

  void _seek(Duration delta) {
    final session = _session;
    if (session != null) _seekBy(session.player, delta);
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) unawaited(session.dispose());
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.onDescriptor(
      widget.pageIndex,
      ViewerChromeDescriptor(
        actions: cloudMediaActions(context, ref, widget.file),
        infoBuilder: (context) => cloudMediaInfo(widget.file),
        onSeekBackward: () => _seek(-_seekStep),
        onSeekForward: () => _seek(_seekStep),
      ),
    );

    final cloudThumb = ThumbnailService.instance.cachedCloud(widget.file.id);
    final localThumb = widget.localAsset == null
        ? null
        : ThumbnailService.instance.cachedLocal(widget.localAsset!.id);
    if (_failed) {
      return _errorView(
        message: 'Could not load this video.',
        onRetry: _retry,
        cloudThumb: cloudThumb,
        localThumb: localThumb,
      );
    }
    final session = _session;
    if (!_ready || session == null) {
      return _loadingPreview(
        cloudThumb: cloudThumb,
        localThumb: localThumb,
        progress: _progress,
      );
    }
    // No InteractiveViewer here (unlike the photo pages): its scale
    // recognizer claims a single-finger drag's pointer in the gesture arena
    // the instant it starts, regardless of panEnabled — that flag only gates
    // what _onScaleUpdate *does* with the movement, not whether
    // InteractiveViewer's own GestureDetector wins the arena over
    // ViewerChromeHost's swipe-down-to-dismiss and swipe-up-for-info
    // (verified against the framework's own interactive_viewer.dart:
    // _onScaleUpdate calls widget.onInteractionUpdate and returns early when
    // the gesture type isn't supported, but by then the recognizer has
    // already accepted the gesture). Video was never asked to support
    // pinch-zoom, so leaving InteractiveViewer out here — rather than trying
    // to out-race it — is what actually lets those two gestures reach the
    // video page at all.
    //
    // `wakelock` (media_kit_video's default, spelled out): the screen is kept
    // on only while this Video is playing — the app holds no permanent
    // wakelock of its own any more.
    return Video(
      controller: session.controller,
      controls: videoSeekControls(),
      wakelock: true,
    );
  }
}

// ---------------------------------------------------------------------------
// Shared actions/info for a cloud FileItem — used by the viewer chrome above
// and by multi-select action bars (Gallery, Albums, Files).
// ---------------------------------------------------------------------------

/// Shares one or more cloud files, downloading to cache first as needed
/// (already-cached or backup-linked files share instantly).
Future<void> shareCloudFiles(BuildContext context, List<FileItem> files) async {
  try {
    final locals = await Future.wait(
      files.map(DownloadService.instance.downloadToCache),
    );
    await SharePlus.instance.share(
      ShareParams(files: locals.map((f) => XFile(f.path)).toList()),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not share: $e')));
    }
  }
}

List<ViewerAction> cloudMediaActions(
  BuildContext context,
  WidgetRef ref,
  FileItem file,
) {
  final saved = ref.watch(_savedProvider(file)).valueOrNull ?? false;
  // Re-derived from the live index (not the `file` snapshot passed in) so
  // toggling Archive/Unarchive updates this row immediately even though the
  // viewer's page list itself is a fixed snapshot from when it was opened.
  final archived = ref.watch(_archivedProvider(file.id));
  // The Download action below never surfaced saveToDevice failures — the
  // notifier records them as DownloadState.error rather than throwing, so
  // without this listener a failed save just silently did nothing.
  ref.listen(downloadProvider, (prev, next) {
    if (next.error != null && next.error != prev?.error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: ${next.error}')));
    }
  });
  return [
    ViewerAction(
      icon: Icons.share_outlined,
      label: 'Share',
      onTap: () => shareCloudFiles(context, [file]),
    ),
    // Cloud-backup status: always uploaded here — informational.
    const ViewerAction(
      icon: Icons.cloud_done_outlined,
      label: 'Uploaded',
      onTap: null,
    ),
    // Device-presence status: Download (pending) or On device (done).
    ViewerAction(
      icon: saved ? Icons.smartphone : Icons.download_outlined,
      label: saved ? 'On device' : 'Download',
      onTap: saved
          ? null
          : () async {
              await ref.read(downloadProvider.notifier).saveToDevice(file);
              bumpDeviceState(ref);
            },
    ),
    ViewerAction(
      icon: Icons.playlist_add,
      label: 'Add to album',
      onTap: () => addFileIdsToAlbum(context, ref, [file.id]),
    ),
    ViewerAction(
      icon: archived ? Icons.unarchive_outlined : Icons.archive_outlined,
      label: archived ? 'Unarchive' : 'Archive',
      onTap: () => archived
          ? ref.read(indexProvider.notifier).unarchiveFiles([file.id])
          : ref.read(indexProvider.notifier).archiveFiles([file.id]),
    ),
    ViewerAction(
      icon: Icons.delete_outline,
      label: 'Delete',
      color: Colors.redAccent,
      onTap: () => _deleteFile(context, ref, file),
    ),
  ];
}

final _savedProvider = FutureProvider.family.autoDispose<bool, FileItem>((
  ref,
  file,
) {
  ref.watch(deviceStateVersion);
  return LocalFileService.instance.isSaved(file);
});

/// Current archived state of [fileId] per the live index — not the `file`
/// snapshot [cloudMediaActions] receives, which can be stale by the time the
/// user acts (the viewer's page list is captured once when it opens).
final _archivedProvider = Provider.family<bool, String>((ref, fileId) {
  final index = ref.watch(indexProvider).index;
  for (final f in index.files) {
    if (f.id == fileId) return f.archived;
  }
  return false;
});

Future<void> _deleteFile(
  BuildContext context,
  WidgetRef ref,
  FileItem file,
) async {
  final registry = BackupRegistry.instance;
  // Same lookup the "On device" action row icon uses — a raw
  // BackupRegistry.localPathFor() check alone misses files saved via the
  // explicit "Save to device" download (a plain Downloads-folder copy, not a
  // backup link), which showed the icon as on-device while this dialog
  // still only offered "delete from Telegram".
  final match = await LocalFileService.instance.existingLocalFile(file);
  if (!context.mounted) return;

  final source = await askDeleteSource(
    context,
    existsOnDevice: match != null,
    existsInCloud: true,
  );
  if (source == null || !context.mounted) return;

  if (source == DeleteSource.cloud || source == DeleteSource.both) {
    await ref.read(indexProvider.notifier).deleteFiles([file]);
    // deleteFiles doesn't rethrow on failure (it records mutationError and
    // keeps the item in the index) — closing the viewer here would make a
    // failed Telegram delete look like it succeeded.
    if (ref.read(indexProvider).mutationError != null) return;
  }
  if ((source == DeleteSource.device || source == DeleteSource.both) &&
      match != null) {
    if (match.isLinkedAsset) {
      final assetId = registry.assetIdForFileItem(file.id);
      if (assetId != null) {
        await PhotoManager.editor.deleteWithIds([assetId]);
        await PhotoManager.clearFileCache();
      }
    } else {
      await match.file.delete();
    }
  }
  bumpDeviceState(ref);
  if (context.mounted) Navigator.pop(context);
}

Widget cloudMediaInfo(FileItem file) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        file.name,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      _InfoRow(
        icon: Icons.calendar_today_outlined,
        text: _formatDate(file.createdAt),
      ),
      _InfoRow(
        icon: Icons.sd_storage_outlined,
        text: humanFileSize(file.totalSize),
      ),
      _InfoRow(icon: Icons.image_outlined, text: file.mimeType),
      if (file.isMultiPart)
        _InfoRow(
          icon: Icons.layers_outlined,
          text: '${file.parts.length} parts',
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Local pages — an AssetEntity that lives only on the device.
// ---------------------------------------------------------------------------

class LocalImagePage extends ConsumerStatefulWidget {
  const LocalImagePage({
    super.key,
    required this.asset,
    required this.pageIndex,
    required this.onDescriptor,
    this.zoomLock,
  });
  final AssetEntity asset;

  /// See [CloudImagePage.pageIndex]/[CloudImagePage.onDescriptor].
  final int pageIndex;
  final void Function(int pageIndex, ViewerChromeDescriptor descriptor)
  onDescriptor;

  /// The enclosing viewer screen's PageView freeze flag. See [ViewerZoomLock].
  final ViewerZoomLock? zoomLock;

  @override
  ConsumerState<LocalImagePage> createState() => _LocalImagePageState();
}

class _LocalImagePageState extends ConsumerState<LocalImagePage>
    with SingleTickerProviderStateMixin {
  File? _local;
  bool _failed = false;

  // See _CloudImagePageState above for what this owns and why.
  late final PhotoZoomController _zoom = PhotoZoomController(this);

  void _reportZoom() => widget.zoomLock?.report(_zoom.zoomed.value);

  void _onHighResChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _zoom.zoomed.addListener(_reportZoom);
    _zoom.highRes.addListener(_onHighResChanged);
    _load();
  }

  Future<void> _load() async {
    try {
      final f = await widget.asset.file;
      if (!mounted) return;
      if (f == null) {
        setState(() => _failed = true);
      } else {
        setState(() => _local = f);
      }
    } catch (e) {
      debugPrint('TVDIAG: viewer local image load failed (${e.runtimeType})');
      if (mounted) setState(() => _failed = true);
    }
  }

  void _retry() {
    setState(() => _failed = false);
    _load();
  }

  @override
  void dispose() {
    _zoom.zoomed.removeListener(_reportZoom);
    _zoom.highRes.removeListener(_onHighResChanged);
    widget.zoomLock?.report(false);
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final local = _local;
    // localMediaActions/Info need the resolved File (unlike the cloud pages'
    // actions, which only need the FileItem), so a full descriptor can only
    // be reported once loaded — while loading, still report the zoom bits
    // (harmless; there's nothing to double-tap-zoom yet anyway).
    widget.onDescriptor(
      widget.pageIndex,
      local == null
          ? ViewerChromeDescriptor(
              onDoubleTapZoom: _zoom.toggleZoom,
              zoomed: _zoom.zoomed,
            )
          : ViewerChromeDescriptor(
              actions: localMediaActions(context, ref, widget.asset, local),
              infoBuilder: (context) => localMediaInfo(widget.asset, local),
              onDoubleTapZoom: _zoom.toggleZoom,
              zoomed: _zoom.zoomed,
            ),
    );

    final localThumb = ThumbnailService.instance.cachedLocal(widget.asset.id);
    if (_failed) {
      return _errorView(
        message: 'Could not read this photo from the device.',
        onRetry: _retry,
        localThumb: localThumb,
      );
    }
    if (local == null) return _loadingPreview(localThumb: localThumb);
    return _zoomableImage(
      context,
      file: local,
      zoom: _zoom,
      highRes: _zoom.highRes.value,
      placeholder: _thumbPreview(localThumb: localThumb),
    );
  }
}

class LocalVideoPage extends ConsumerStatefulWidget {
  const LocalVideoPage({
    super.key,
    required this.asset,
    required this.pageIndex,
    required this.onDescriptor,
    required this.isCurrent,
  });
  final AssetEntity asset;

  /// See [CloudImagePage.pageIndex]/[CloudImagePage.onDescriptor].
  final int pageIndex;
  final void Function(int pageIndex, ViewerChromeDescriptor descriptor)
  onDescriptor;

  /// See [CloudVideoPage.isCurrent].
  final bool isCurrent;

  @override
  ConsumerState<LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends ConsumerState<LocalVideoPage> {
  // See _CloudVideoPageState: created in _load only.
  _VideoSession? _session;
  bool _ready = false;
  bool _started = false;
  bool _opened = false;
  bool _failed = false;
  File? _local;

  @override
  void initState() {
    super.initState();
    if (widget.isCurrent) _load();
  }

  @override
  void didUpdateWidget(LocalVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isCurrent == widget.isCurrent) return;
    if (widget.isCurrent) {
      if (!_started) {
        _load();
      } else if (_opened) {
        _session?.player.play();
      }
    } else if (_opened) {
      _session?.player.pause();
    }
  }

  Future<void> _load() async {
    _started = true;
    try {
      final file = await widget.asset.file;
      if (file == null) throw const FileSystemException('device file unavailable');
      if (!mounted) return;
      final session = _session ??= _VideoSession();
      await session.open(file);
      if (!mounted) return;
      _opened = true;
      if (widget.isCurrent) session.player.play();
      setState(() {
        _ready = true;
        _local = file;
      });
      unawaited(
        session.watchFirstFrame(file, shouldPlay: () => mounted && widget.isCurrent),
      );
    } catch (e) {
      debugPrint('TVDIAG: viewer local video load failed (${e.runtimeType})');
      if (mounted) setState(() => _failed = true);
    }
  }

  void _retry() {
    setState(() => _failed = false);
    _load();
  }

  void _seek(Duration delta) {
    final session = _session;
    if (session != null) _seekBy(session.player, delta);
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) unawaited(session.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final local = _local;
    widget.onDescriptor(
      widget.pageIndex,
      local == null
          ? const ViewerChromeDescriptor()
          : ViewerChromeDescriptor(
              actions: localMediaActions(context, ref, widget.asset, local),
              infoBuilder: (context) => localMediaInfo(widget.asset, local),
              onSeekBackward: () => _seek(-_seekStep),
              onSeekForward: () => _seek(_seekStep),
            ),
    );

    final localThumb = ThumbnailService.instance.cachedLocal(widget.asset.id);
    if (_failed) {
      return _errorView(
        message: 'Could not read this video from the device.',
        onRetry: _retry,
        localThumb: localThumb,
      );
    }
    final session = _session;
    if (!_ready || local == null || session == null) {
      return _loadingPreview(localThumb: localThumb);
    }
    // See CloudVideoPage's build for why there's no InteractiveViewer here.
    return Video(
      controller: session.controller,
      controls: videoSeekControls(),
      wakelock: true,
    );
  }
}

// ---------------------------------------------------------------------------
// Shared actions/info for a local device asset.
// ---------------------------------------------------------------------------

/// Tracks per-asset upload state so the viewer's Upload/Uploaded action
/// updates immediately after uploading, instead of only on the next rebuild.
/// Recomputes on every [deviceStateVersion] bump, so any upload/delete
/// anywhere in the app keeps this in sync.
final _uploadedProvider = Provider.family<bool, String>((ref, assetId) {
  ref.watch(deviceStateVersion);
  return BackupRegistry.instance.isUploaded(assetId);
});

List<ViewerAction> localMediaActions(
  BuildContext context,
  WidgetRef ref,
  AssetEntity asset,
  File localFile,
) {
  final uploaded = ref.watch(_uploadedProvider(asset.id));
  return [
    ViewerAction(
      icon: Icons.share_outlined,
      label: 'Share',
      onTap: () =>
          SharePlus.instance.share(ShareParams(files: [XFile(localFile.path)])),
    ),
    // Cloud-backup status: Upload (pending) or Uploaded (done).
    ViewerAction(
      icon: uploaded ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
      label: uploaded ? 'Uploaded' : 'Upload',
      onTap: uploaded ? null : () => _uploadAsset(context, ref, asset),
    ),
    // Device-presence status: always on device here — informational.
    const ViewerAction(icon: Icons.smartphone, label: 'On device', onTap: null),
    ViewerAction(
      icon: Icons.playlist_add,
      label: 'Add to album',
      onTap: () async {
        final fileItemId = await _resolveFileItemId(context, ref, asset);
        if (fileItemId != null && context.mounted) {
          await addFileIdsToAlbum(context, ref, [fileItemId]);
        }
      },
    ),
    ViewerAction(
      icon: Icons.delete_outline,
      label: 'Delete',
      color: Colors.redAccent,
      onTap: () => _deleteAsset(context, ref, asset),
    ),
  ];
}

Future<void> _deleteAsset(
  BuildContext context,
  WidgetRef ref,
  AssetEntity asset,
) async {
  final registry = BackupRegistry.instance;
  final existsInCloud = registry.isUploaded(asset.id);

  final source = await askDeleteSource(
    context,
    existsOnDevice: true,
    existsInCloud: existsInCloud,
  );
  if (source == null || !context.mounted) return;

  try {
    var deletedFromDevice = false;
    var deviceDeleteCancelled = false;
    if (source == DeleteSource.device || source == DeleteSource.both) {
      // On Android 11+, deleting media this app didn't create shows a
      // separate SYSTEM confirmation dialog on top of ours — if it's
      // declined (or missed), Android reports nothing deleted.
      final deleted = await PhotoManager.editor.deleteWithIds([asset.id]);
      deletedFromDevice = deleted.isNotEmpty;
      deviceDeleteCancelled = !deletedFromDevice;
      if (deletedFromDevice) {
        await PhotoManager.clearFileCache();
        await ref.read(backupProvider.notifier).refreshDeviceAlbums();
      }
    }
    if (source == DeleteSource.cloud || source == DeleteSource.both) {
      final fileItemId = registry.fileItemIdFor(asset.id);
      FileItem? fileItem;
      if (fileItemId != null) {
        for (final f in ref.read(indexProvider).index.files) {
          if (f.id == fileItemId) {
            fileItem = f;
            break;
          }
        }
      }
      if (fileItem != null)
        await ref.read(indexProvider.notifier).deleteFiles([fileItem]);
    }
    bumpDeviceState(ref);

    if (!context.mounted) return;
    if (deviceDeleteCancelled && source == DeleteSource.device) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Delete cancelled — Android's own confirmation wasn't approved.",
          ),
        ),
      );
      return;
    }
    // deleteFiles doesn't rethrow on failure — check explicitly so a failed
    // Telegram delete doesn't close the viewer as if it had succeeded.
    if (ref.read(indexProvider).mutationError != null) return;
    if (deletedFromDevice || source == DeleteSource.cloud) {
      Navigator.of(context).pop();
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }
}

Future<String?> _resolveFileItemId(
  BuildContext context,
  WidgetRef ref,
  AssetEntity asset,
) async {
  final existing = BackupRegistry.instance.fileItemIdFor(asset.id);
  if (existing != null) return existing;
  return _uploadAsset(context, ref, asset);
}

/// Uploads [asset] and links it in the backup registry. Returns the new
/// file's id, or null if the upload failed.
Future<String?> _uploadAsset(
  BuildContext context,
  WidgetRef ref,
  AssetEntity asset,
) async {
  try {
    final fileItem = await AssetUploadService.instance.uploadAndLink(
      ref,
      asset,
    );
    bumpDeviceState(ref);
    return fileItem.id;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
    return null;
  }
}

Widget localMediaInfo(AssetEntity asset, File localFile) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        asset.title ?? 'Untitled',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      _InfoRow(
        icon: Icons.calendar_today_outlined,
        text: _formatDate(asset.createDateTime),
      ),
      _InfoRow(
        icon: Icons.aspect_ratio_outlined,
        text: '${asset.width} × ${asset.height}',
      ),
      FutureBuilder<int>(
        future: localFile.length(),
        builder: (context, snapshot) => _InfoRow(
          icon: Icons.sd_storage_outlined,
          text: snapshot.hasData ? humanFileSize(snapshot.data!) : '…',
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Shared small widgets/helpers.
// ---------------------------------------------------------------------------

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.white54),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final ampm = local.hour < 12 ? 'AM' : 'PM';
  final minute = local.minute.toString().padLeft(2, '0');
  return '${months[local.month - 1]} ${local.day}, ${local.year} · $hour:$minute $ampm';
}
