import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/preview/video_controls.dart';

void main() {
  group('TapToSeek.fractionAt', () {
    test('maps the track between the margins to 0..1', () {
      // 400 wide, 16 margin each side -> track is x in [16, 384].
      expect(TapToSeek.fractionAt(16, 400, 16), 0);
      expect(TapToSeek.fractionAt(200, 400, 16), closeTo(0.5, 1e-9));
      expect(TapToSeek.fractionAt(384, 400, 16), 1);
    });

    test('clamps taps on the margins', () {
      expect(TapToSeek.fractionAt(4, 400, 16), 0);
      expect(TapToSeek.fractionAt(398, 400, 16), 1);
    });

    test('degenerate width does not divide by zero', () {
      expect(TapToSeek.fractionAt(10, 20, 16), 0);
    });
  });

  group('seek bar hit area', () {
    test('keeps the bar line where it was while the hit area grows', () {
      // Old layout: 36 dp container bottom-aligned, bar line (2.4) at its
      // bottom, margin.bottom = inset + kViewerBottomBarHeight + 12.
      const oldLineCentreAboveBottom = 108.0 + 12 + 1.2; // inset 0
      // New layout: line centre is kSeekBarHitBelow above the container's
      // bottom, which sits seekBarBottomMargin above the bottom.
      final newLineCentre = seekBarBottomMargin(0) + kSeekBarHitBelow;
      expect(newLineCentre, closeTo(oldLineCentreAboveBottom, 1e-9));
      expect(kSeekBarHitHeight - 36, inInclusiveRange(12, 16));
      // The container never dips below the bottom action row's top edge.
      expect(seekBarBottomMargin(0), greaterThanOrEqualTo(108));
    });
  });
}
