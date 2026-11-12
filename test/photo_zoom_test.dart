import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/preview/widgets/photo_zoom_controller.dart';
import 'package:tele_vault/features/preview/widgets/viewer_page_chrome.dart';

// Pins the three zoom behaviours the user reported broken on device:
//   1. double tap did nothing (no zoom in, and therefore no way back out),
//   2. dragging a zoomed photo left/right paged to the next photo instead of
//      panning around inside it,
//   3. there was no way to zoom back out.
// Everything here runs through Flutter's real gesture arena, so it exercises
// the same path a finger does.

/// A photo page equivalent to what CloudImagePage/LocalImagePage build:
/// ViewerChromeHost owning the taps, an InteractiveViewer owning the
/// pan/scale, and the two wired together through a PhotoZoomController. Only
/// one page exists in this harness, so its descriptor is always "current" —
/// no pageIndex bookkeeping needed the way the real multi-page screens do.
class _ZoomHarness extends StatefulWidget {
  const _ZoomHarness({this.zoomLock, this.onPrevious, this.onNext});

  final ViewerZoomLock? zoomLock;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<_ZoomHarness> createState() => _ZoomHarnessState();
}

class _ZoomHarnessState extends State<_ZoomHarness>
    with SingleTickerProviderStateMixin {
  late final PhotoZoomController zoom = PhotoZoomController(this);
  final ValueNotifier<ViewerChromeDescriptor> _descriptor = ValueNotifier(
    const ViewerChromeDescriptor(),
  );

  void _report() => widget.zoomLock?.report(zoom.zoomed.value);

  @override
  void initState() {
    super.initState();
    zoom.zoomed.addListener(_report);
  }

  @override
  void dispose() {
    zoom.zoomed.removeListener(_report);
    widget.zoomLock?.report(false);
    zoom.dispose();
    _descriptor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _descriptor.value = ViewerChromeDescriptor(
      infoBuilder: (context) => const Text('info panel content'),
      onDoubleTapZoom: zoom.toggleZoom,
      zoomed: zoom.zoomed,
    );
    return ViewerChromeHost(
      descriptor: _descriptor,
      onPrevious: widget.onPrevious,
      onNext: widget.onNext,
      onDismissDragChanged: widget.zoomLock?.reportDragging,
      child: InteractiveViewer(
        transformationController: zoom.transform,
        minScale: 1,
        maxScale: 5,
        child: Center(child: Container(color: Colors.blue)),
      ),
    );
  }
}

Widget _app(_ZoomHarness harness) =>
    MaterialApp(home: Scaffold(body: harness));

_ZoomHarnessState _state(WidgetTester tester) =>
    tester.state<_ZoomHarnessState>(find.byType(_ZoomHarness));

/// tester.tapAt twice inside kDoubleTapTimeout, which is what
/// ViewerChromeHost's hand-rolled single/double-tap disambiguation reads.
Future<void> _doubleTapAt(WidgetTester tester, Offset position) async {
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(position);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('double tap zooms in, and a second double tap zooms back out', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const _ZoomHarness()));
    final zoom = _state(tester).zoom;
    expect(zoom.zoomed.value, isFalse);

    await _doubleTapAt(tester, const Offset(400, 300));
    expect(zoom.zoomed.value, isTrue);
    expect(zoom.transform.value.getMaxScaleOnAxis(), greaterThan(1.01));

    await _doubleTapAt(tester, const Offset(400, 300));
    expect(zoom.zoomed.value, isFalse);
    expect(zoom.transform.value.getMaxScaleOnAxis(), closeTo(1, 0.001));
  });

  testWidgets('zooming anchors on the tapped point, not the centre', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const _ZoomHarness()));
    final zoom = _state(tester).zoom;

    await _doubleTapAt(tester, const Offset(100, 150));
    // Translation is what keeps the tapped point under the finger; a
    // centre-only zoom would leave it at zero.
    final translation = zoom.transform.value.getTranslation();
    expect(translation.x, lessThan(0));
    expect(translation.y, lessThan(0));
  });

  testWidgets('an edge tap does NOT page while zoomed in', (tester) async {
    var previousCount = 0;
    var nextCount = 0;
    await tester.pumpWidget(
      _app(
        _ZoomHarness(
          onPrevious: () => previousCount++,
          onNext: () => nextCount++,
        ),
      ),
    );

    // Not zoomed: the narrow edge zones still page as before.
    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(previousCount, 1);

    await _doubleTapAt(tester, const Offset(400, 300));
    expect(_state(tester).zoom.zoomed.value, isTrue);

    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    await tester.tapAt(const Offset(780, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(previousCount, 1, reason: 'edge tap must not page while zoomed');
    expect(nextCount, 0, reason: 'edge tap must not page while zoomed');
  });

  testWidgets('the screen-level zoom lock freezes the PageView while zoomed', (
    tester,
  ) async {
    final lock = ViewerZoomLock();
    addTearDown(lock.dispose);
    expect(lock.physics, isNull);

    await tester.pumpWidget(_app(_ZoomHarness(zoomLock: lock)));
    await _doubleTapAt(tester, const Offset(400, 300));
    expect(lock.value, isTrue);
    expect(lock.physics, isA<NeverScrollableScrollPhysics>());

    await _doubleTapAt(tester, const Offset(400, 300));
    expect(lock.value, isFalse);
    expect(lock.physics, isNull);
  });

  testWidgets('tearing a zoomed page down releases the lock', (tester) async {
    final lock = ViewerZoomLock();
    addTearDown(lock.dispose);

    await tester.pumpWidget(_app(_ZoomHarness(zoomLock: lock)));
    await _doubleTapAt(tester, const Offset(400, 300));
    expect(lock.value, isTrue);

    // Replace the page, as paging or popping the route would.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
    await tester.pumpAndSettle();
    expect(
      lock.value,
      isFalse,
      reason: 'a latched lock would freeze paging for every later page',
    );
  });

  testWidgets('a drag while zoomed pans the photo instead of opening info', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const _ZoomHarness()));
    await _doubleTapAt(tester, const Offset(400, 300));
    final zoom = _state(tester).zoom;
    final before = zoom.transform.value.getTranslation();

    await tester.drag(find.byType(InteractiveViewer), const Offset(0, 80));
    await tester.pumpAndSettle();

    // ViewerChromeHost's vertical drag stands down while zoomed, so the
    // movement reaches InteractiveViewer and moves the image.
    expect(zoom.transform.value.getTranslation().y, isNot(closeTo(before.y, 1)));
    expect(find.text('info panel content'), findsNothing);
  });
}
