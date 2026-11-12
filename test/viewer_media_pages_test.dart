import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/preview/widgets/media_pages.dart';
import 'package:tele_vault/features/preview/widgets/photo_zoom_controller.dart';
import 'package:tele_vault/features/preview/widgets/viewer_page_chrome.dart';
import 'package:tele_vault/models/file_item.dart';

FileItem _video() => FileItem(
  id: 'vid-1',
  name: 'clip.mp4',
  folderId: null,
  totalSize: 10,
  mimeType: 'video/mp4',
  createdAt: DateTime(2026, 1, 1),
  parts: const [],
);

Widget _videoPage({required bool isCurrent}) => ProviderScope(
  child: MaterialApp(
    home: Scaffold(
      body: CloudVideoPage(
        file: _video(),
        pageIndex: 0,
        onDescriptor: (_, ViewerChromeDescriptor _) {},
        isCurrent: isCurrent,
      ),
    ),
  ),
);

void main() {
  late int created;
  late ViewerPlayerFactory original;

  setUp(() {
    created = 0;
    original = debugPlayerFactory;
    debugPlayerFactory = () {
      created++;
      throw StateError('test: no real Player must be created');
    };
  });

  tearDown(() => debugPlayerFactory = original);

  testWidgets('a neighbour video page disposed before it loads creates no Player', (
    tester,
  ) async {
    await tester.pumpWidget(_videoPage(isCurrent: false));
    await tester.pump();
    // Torn down while never current (PageView dropping a neighbour).
    await tester.pumpWidget(const SizedBox.shrink());
    expect(created, 0);
  });

  testWidgets('load failure shows a generic message and Retry, never the exception text', (
    tester,
  ) async {
    // Current from the start: _load runs, the download path fails in the test
    // environment (no path_provider) and the page lands in its error state.
    await tester.pumpWidget(_videoPage(isCurrent: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Could not load this video.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('MissingPlugin'), findsNothing);
    // The failure happened before any file existed, so still no Player.
    expect(created, 0);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Retry runs the load again', (tester) async {
    await tester.pumpWidget(_videoPage(isCurrent: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Retry'));
    await tester.pump();
    // Back in the loading state for a moment, then the same failure again.
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Could not load this video.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('photoDecodeWidth is 1x screen pixels, 2x when highRes', (tester) async {
    late int fitted;
    late int zoomed;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(400, 800), devicePixelRatio: 3),
        child: Builder(
          builder: (context) {
            fitted = photoDecodeWidth(context);
            zoomed = photoDecodeWidth(context, highRes: true);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(fitted, 1200);
    expect(zoomed, 2400);
  });

  testWidgets('PhotoZoomController.highRes flips at 1.5x with hysteresis', (tester) async {
    late PhotoZoomController zoom;
    await tester.pumpWidget(
      _ZoomOwner(onCreate: (z) => zoom = z),
    );
    expect(zoom.highRes.value, isFalse);

    zoom.transform.value = Matrix4.diagonal3Values(1.4, 1.4, 1);
    expect(zoom.zoomed.value, isTrue);
    expect(zoom.highRes.value, isFalse);

    zoom.transform.value = Matrix4.diagonal3Values(1.6, 1.6, 1);
    expect(zoom.highRes.value, isTrue);

    // Pinching back below the on-threshold does not swap straight back.
    zoom.transform.value = Matrix4.diagonal3Values(1.2, 1.2, 1);
    expect(zoom.highRes.value, isTrue);

    zoom.transform.value = Matrix4.identity();
    expect(zoom.zoomed.value, isFalse);
    expect(zoom.highRes.value, isFalse);
  });
}

class _ZoomOwner extends StatefulWidget {
  const _ZoomOwner({required this.onCreate});
  final void Function(PhotoZoomController) onCreate;

  @override
  State<_ZoomOwner> createState() => _ZoomOwnerState();
}

class _ZoomOwnerState extends State<_ZoomOwner>
    with SingleTickerProviderStateMixin {
  late final PhotoZoomController zoom = PhotoZoomController(this);

  @override
  void initState() {
    super.initState();
    widget.onCreate(zoom);
  }

  @override
  void dispose() {
    zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
