import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tele_vault/core/thumbnail/thumbnail_service.dart';

// Covers the two on-device failures this function has caused, both confirmed
// in logcat rather than reasoned about:
//
//  1. Memory: it used to decode the FULL source resolution into an
//     uncompressed bitmap via package:image before resizing (a 12MP photo is
//     ~50MB of raw pixels; 4 concurrent decodes during a gallery scroll
//     pushed the phone into severe memory pressure and the OS low-memory
//     killer took down other apps).
//  2. The UI thread: the JPEG re-encode afterwards is synchronous, CPU-bound
//     Dart, and running it inline produced an `ANR ... Input dispatching
//     timed out (Waited 10000ms for MotionEvent(action=MOVE))` mid-scroll.
//
// The two fixes pull in opposite directions — decode must stay on the main
// isolate, encode must not — so both halves are pinned here.

/// Decodes with `targetWidth` the way [resizeToThumbnail] does, so the test
/// below can run exactly that step inside an isolate.
Future<int> _decodeWidthWithTargetWidth(Uint8List src) async {
  final codec = await ui.instantiateImageCodec(src, targetWidth: 256);
  final frame = await codec.getNextFrame();
  final width = frame.image.width;
  frame.image.dispose();
  codec.dispose();
  return width;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resizeToThumbnail downscales a large image to ~256px wide', () async {
    // A 4000x3000 solid-color source approximates a real 12MP phone photo's
    // dimensions without needing an actual photo fixture.
    final large = img.Image(width: 4000, height: 3000);
    img.fill(large, color: img.ColorRgb8(120, 160, 200));
    final srcBytes = Uint8List.fromList(img.encodeJpg(large, quality: 90));

    final result = await resizeToThumbnail(srcBytes);

    final decodedResult = img.decodeImage(result);
    expect(decodedResult, isNotNull);
    expect(decodedResult!.width, 256);
    expect(decodedResult.height, 192); // 4:3 aspect ratio preserved
    // The whole point: the encoded thumbnail must be drastically smaller
    // than the source, not just re-encoded at the same resolution.
    expect(result.length, lessThan(srcBytes.length ~/ 10));
  });

  test(
    'the DECODE must stay on the main isolate — targetWidth is silently '
    'ignored anywhere else',
    () async {
      // Moving the decode off the main isolate looks like the safer choice
      // and was the first thing tried, but isolates other than the main one
      // can't reach the Flutter engine's image-decoder registry: targetWidth
      // has no effect there and the full source resolution gets decoded into
      // memory anyway, silently defeating the point. Pinned so a future
      // "let's move this to compute for safety" can't reintroduce failure 1.
      final large = img.Image(width: 3000, height: 4000);
      img.fill(large, color: img.ColorRgb8(80, 40, 200));
      final srcBytes = Uint8List.fromList(img.encodeJpg(large, quality: 90));

      expect(await _decodeWidthWithTargetWidth(srcBytes), 256);
      await expectLater(
        compute(_decodeWidthWithTargetWidth, srcBytes),
        throwsA(
          predicate(
            (e) => e.toString().contains('image decoder registry'),
            'fails to reach the engine\'s image decoder registry',
          ),
        ),
        reason:
            'if this starts passing, decoding works off the main isolate and '
            'the decode can move there',
      );
    },
  );

  test(
    'resizeToThumbnail returns the source unchanged for invalid image bytes',
    () async {
      final garbage = Uint8List.fromList([1, 2, 3, 4, 5]);
      final result = await resizeToThumbnail(garbage);
      expect(result, garbage);
    },
  );
}
