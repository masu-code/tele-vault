import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/preview/video_controls.dart';
import 'package:tele_vault/features/preview/widgets/viewer_page_chrome.dart';

// Drives ViewerChromeHost's gesture logic directly with tester.tapAt/drag —
// these go through Flutter's real gesture-arena pipeline (unlike a raw adb
// input event), so this is a genuine test of the same mechanism a physical
// tap exercises, without needing a device, a real video player, or network
// access. Written to pin down exactly the behavior the user reported broken:
// swipe-down-to-dismiss on a video page, and the half-screen double-tap-seek
// zone being independent from the narrow single-tap edge zone.
//
// Only one page's worth of state exists here (a single, unchanging
// descriptor for the test's duration) — the real app has one ViewerChromeHost
// per screen with multiple pages reporting into it as the current page
// changes, but that machinery isn't what's under test here.

Widget _harness({
  VoidCallback? onBack,
  VoidCallback? onPrevious,
  VoidCallback? onNext,
  VoidCallback? onSeekBackward,
  VoidCallback? onSeekForward,
  ValueChanged<bool>? onDismissDragChanged,
  List<ViewerAction> actions = const [],
  Widget? child,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ViewerChromeHost(
        // A plain colored box, not a real Video widget — CloudVideoPage /
        // LocalVideoPage don't wrap this in an InteractiveViewer anymore
        // (that's the actual fix under test: InteractiveViewer's scale
        // recognizer used to win the gesture arena over this widget's own
        // vertical drag regardless of panEnabled), so nothing here should
        // either.
        child: child ?? Container(color: Colors.black),
        descriptor: ValueNotifier(
          ViewerChromeDescriptor(
            actions: actions,
            infoBuilder: (context) => const Text('info panel content'),
            onSeekBackward: onSeekBackward,
            onSeekForward: onSeekForward,
          ),
        ),
        onBack: onBack,
        onPrevious: onPrevious,
        onNext: onNext,
        onDismissDragChanged: onDismissDragChanged,
      ),
    ),
  );
}

/// Page content with a tappable control. [shielded] wraps it in a
/// [ViewerTapShield]. [visible] receives the host's chrome-visibility flag.
Widget _pageWithControl({
  required Alignment at,
  required bool shielded,
  required VoidCallback onControlTap,
  void Function(ValueListenable<bool>?)? visible,
}) {
  return Builder(
    builder: (context) {
      visible?.call(ViewerChromeVisibility.maybeOf(context));
      Widget control = GestureDetector(
        onTap: onControlTap,
        child: const SizedBox(width: 40, height: 40, child: ColoredBox(color: Colors.red)),
      );
      if (shielded) control = ViewerTapShield(child: control);
      return Stack(
        children: [
          Positioned.fill(child: Container(color: Colors.black)),
          Align(alignment: at, child: control),
        ],
      );
    },
  );
}

void main() {
  group('ViewerTapShield', () {
    testWidgets('a tap on a shielded control at the right edge does not page', (
      tester,
    ) async {
      var next = 0;
      var control = 0;
      await tester.pumpWidget(
        _harness(
          onNext: () => next++,
          child: _pageWithControl(
            at: Alignment.centerRight,
            shielded: true,
            onControlTap: () => control++,
          ),
        ),
      );
      await tester.tapAt(const Offset(790, 300));
      await tester.pumpAndSettle();
      expect(control, 1, reason: 'the control still gets its tap');
      expect(next, 0);
    });

    testWidgets('a tap on a shielded control in the middle does not toggle '
        'the chrome', (tester) async {
      ValueListenable<bool>? visible;
      var control = 0;
      await tester.pumpWidget(
        _harness(
          child: _pageWithControl(
            at: Alignment.center,
            shielded: true,
            onControlTap: () => control++,
            visible: (v) => visible = v,
          ),
        ),
      );
      expect(visible!.value, isTrue);
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(control, 1);
      expect(visible!.value, isTrue);
      // The claim is cleared: a plain tap elsewhere toggles as before.
      await tester.tapAt(const Offset(300, 100));
      await tester.pumpAndSettle();
      expect(visible!.value, isFalse);
    });

    testWidgets('the same control without the shield still pages and toggles', (
      tester,
    ) async {
      var next = 0;
      ValueListenable<bool>? visible;
      await tester.pumpWidget(
        _harness(
          onNext: () => next++,
          child: _pageWithControl(
            at: Alignment.centerRight,
            shielded: false,
            onControlTap: () {},
            visible: (v) => visible = v,
          ),
        ),
      );
      await tester.tapAt(const Offset(790, 300));
      await tester.pumpAndSettle();
      expect(next, 1);
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(visible!.value, isFalse);
    });

    testWidgets('a shielded pointer that is cancelled leaves no stale claim', (
      tester,
    ) async {
      var next = 0;
      await tester.pumpWidget(
        _harness(
          onNext: () => next++,
          child: _pageWithControl(
            at: Alignment.centerRight,
            shielded: true,
            onControlTap: () {},
          ),
        ),
      );
      final g = await tester.startGesture(const Offset(790, 300));
      await g.cancel();
      await tester.pump();
      // A plain edge tap next to the control (pointer ids are not reused, but
      // the claimed set must be empty): still pages.
      await tester.tapAt(const Offset(790, 200));
      await tester.pumpAndSettle();
      expect(next, 1);
    });
  });

  group('ViewerFullscreen', () {
    testWidgets('one shared state across buttons; the host restores on dispose',
        (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        _harness(
          child: const Padding(
            padding: EdgeInsets.only(top: 200),
            child: Column(
              children: [
                FullscreenToggleButton(key: ValueKey('a')),
                FullscreenToggleButton(key: ValueKey('b')),
              ],
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.fullscreen), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('a')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fullscreen_exit), findsNWidgets(2),
          reason: 'the other button reflects the shared state');
      final enteredCalls = calls.length;
      expect(enteredCalls, greaterThan(0));

      // Leaving the viewer while on restores the screen.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(calls.length, greaterThan(enteredCalls));
    });

    testWidgets('without a host the button works on its own', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: FullscreenToggleButton())),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    });
  });

  testWidgets('single tap in the narrow left edge calls onPrevious', (
    tester,
  ) async {
    var previousCount = 0;
    await tester.pumpWidget(_harness(onPrevious: () => previousCount++));
    // Screen is 800x600 by default in tests; edge zone is 12% of width, so
    // x=20 (2.5%) is comfortably inside it.
    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();
    expect(previousCount, 1);
  });

  testWidgets('single tap in the narrow right edge calls onNext', (
    tester,
  ) async {
    var nextCount = 0;
    await tester.pumpWidget(_harness(onNext: () => nextCount++));
    await tester.tapAt(const Offset(780, 300));
    await tester.pumpAndSettle();
    expect(nextCount, 1);
  });

  testWidgets('single tap in the middle does NOT call onPrevious/onNext', (
    tester,
  ) async {
    var previousCount = 0;
    var nextCount = 0;
    await tester.pumpWidget(
      _harness(onPrevious: () => previousCount++, onNext: () => nextCount++),
    );
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(previousCount, 0);
    expect(nextCount, 0);
  });

  testWidgets(
    'double-tap in the left HALF (not just the narrow edge) seeks backward',
    (tester) async {
      var seekBackCount = 0;
      var previousCount = 0;
      await tester.pumpWidget(
        _harness(
          onSeekBackward: () => seekBackCount++,
          onPrevious: () => previousCount++,
        ),
      );
      // x=250 is in the left half (width 800) but well outside the narrow
      // 12%-of-width single-tap edge zone (96px) — this is exactly the
      // "double-tap can land anywhere in its half" behavior requested.
      const pos = Offset(250, 300);
      await tester.tapAt(pos);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(pos);
      await tester.pumpAndSettle();
      expect(seekBackCount, 1);
      expect(
        previousCount,
        0,
        reason: 'a double-tap must not also register as paging',
      );
    },
  );

  testWidgets('double-tap in the right half seeks forward', (tester) async {
    var seekForwardCount = 0;
    await tester.pumpWidget(_harness(onSeekForward: () => seekForwardCount++));
    const pos = Offset(550, 300);
    await tester.tapAt(pos);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(pos);
    await tester.pumpAndSettle();
    expect(seekForwardCount, 1);
  });

  testWidgets(
    'a single tap on a video page (seek callbacks present) toggles chrome '
        "immediately, and a late second tap that misses the double-tap "
        'window resolves cleanly',
    (tester) async {
      // Taps act immediately now (see _onTapUp) — this only guards against a
      // regression back to delaying every tap while it waits to see if a
      // second one follows.
      await tester.pumpWidget(
        _harness(onSeekBackward: () {}, onSeekForward: () {}),
      );
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('swipe down from the top dismisses the page (pops the route) — '
      'this is the exact gesture that used to be eaten by InteractiveViewer', (
    tester,
  ) async {
    var backCalled = false;
    await tester.pumpWidget(_harness(onBack: () => backCalled = true));
    await tester.drag(find.byType(ViewerChromeHost), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(backCalled, isTrue);
  });

  testWidgets(
    'a small swipe down that does not cross the dismiss threshold snaps back, no onBack',
    (tester) async {
      var backCalled = false;
      await tester.pumpWidget(_harness(onBack: () => backCalled = true));
      // Well under the 120px distance threshold and slow (no velocity kick).
      await tester.drag(find.byType(ViewerChromeHost), const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(backCalled, isFalse);
    },
  );

  testWidgets('swipe up reveals the info panel content', (tester) async {
    await tester.pumpWidget(_harness());
    expect(find.text('info panel content'), findsNothing);
    await tester.drag(find.byType(ViewerChromeHost), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('info panel content'), findsOneWidget);
  });

  testWidgets(
    'a diagonal swipe down (well off pure vertical) still dismisses — this '
        'is the "tenía que ser una línea vertical perfecta" complaint',
    (tester) async {
      var backCalled = false;
      await tester.pumpWidget(_harness(onBack: () => backCalled = true));
      // dx=250, dy=500 is ~26° off vertical (well past a "perfect line") but
      // still clearly more vertical than horizontal — should register as a
      // dismiss, not get lost to a hypothetical horizontal recognizer.
      final gesture = await tester.startGesture(const Offset(400, 100));
      await gesture.moveBy(const Offset(250, 500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(backCalled, isTrue);
    },
  );

  testWidgets(
    'a mostly-horizontal drag does not dismiss and does not toggle chrome — '
        "it's left alone for the enclosing PageView",
    (tester) async {
      var backCalled = false;
      await tester.pumpWidget(_harness(onBack: () => backCalled = true));
      final gesture = await tester.startGesture(const Offset(400, 300));
      await gesture.moveBy(const Offset(300, 40));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(backCalled, isFalse);
    },
  );

  testWidgets(
    'onDismissDragChanged reports true for the duration of a vertical drag '
        'and false once it ends — this is what freezes the PageView',
    (tester) async {
      final states = <bool>[];
      await tester.pumpWidget(
        _harness(onDismissDragChanged: states.add),
      );
      final gesture = await tester.startGesture(const Offset(400, 100));
      await gesture.moveBy(const Offset(0, 20)); // past the axis-decision slop
      expect(states, [true]);
      await gesture.moveBy(const Offset(0, 20));
      expect(
        states,
        [true],
        reason: 'should not re-report true repeatedly mid-drag',
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(states, [true, false]);
    },
  );

  testWidgets(
    'a second finger touching down mid vertical-drag releases the freeze '
        '(about to become a pinch)',
    (tester) async {
      final states = <bool>[];
      await tester.pumpWidget(
        _harness(onDismissDragChanged: states.add),
      );
      final first = await tester.startGesture(const Offset(400, 100));
      await first.moveBy(const Offset(0, 20));
      expect(states, [true]);
      final second = await tester.startGesture(const Offset(420, 120));
      expect(states, [true, false]);
      await first.up();
      await second.up();
    },
  );
}
