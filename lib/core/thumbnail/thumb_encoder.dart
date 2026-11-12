import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Decodes, downscales, and JPEG-re-encodes to a 256px-wide thumbnail.
/// Returns the original bytes (the very same instance) if decoding fails.
///
/// Decodes via [ui.instantiateImageCodec]'s `targetWidth` (Skia's own,
/// natively-subsampled decode — for JPEG this engages libjpeg's DCT
/// scaling, so the full source resolution is never materialized as an
/// uncompressed bitmap), NOT `package:image`'s `decodeImage`, which decodes
/// at full resolution before any resizing. A modern phone photo (12+ MP)
/// decoded that way is ~50MB of raw pixels, and with up to 4 of these
/// running concurrently, that's ~200MB of transient allocation — enough to
/// push a phone into severe memory pressure and take down other apps via the
/// OS's low-memory killer (confirmed via logcat during an on-device crash).
/// `package:image` is still used, but only to JPEG-encode the already-small
/// decoded frame — its own decoder never touches the full-resolution source.
///
/// The work is split across two execution contexts on purpose, and the split
/// is not interchangeable:
///
/// - **Decode stays on the main isolate.** Isolates other than the main one
///   can't reach the Flutter engine's internal image-decoder registry, so
///   `targetWidth` is silently ignored there and the *full* source
///   resolution gets decoded and held in memory anyway — verified with a
///   failing test, not assumed. Skia's decode runs on its own native threads
///   regardless, so it doesn't block the Dart event loop from here.
/// - **JPEG re-encode goes to a helper isolate.** `package:image`'s
///   `encodeJpg` is synchronous, CPU-bound Dart. Running it inline blocked
///   the UI thread hard enough to trip Android's watchdog: an on-device
///   `ANR ... Input dispatching timed out (Waited 10000ms for
///   MotionEvent(action=MOVE))` while scrolling the gallery. It doesn't
///   touch the engine, so unlike the decode it isolates cleanly. One
///   long-lived helper isolate serves every call (spawning an isolate per
///   thumbnail, as `compute` does, cost more than the encode itself).
Future<Uint8List> resizeToThumbnail(Uint8List src) async {
  final ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(src, targetWidth: 256);
  } catch (_) {
    // Unlike package:image's decodeImage, an unparseable source throws here
    // rather than returning null — preserve the original "give up gracefully"
    // behavior for corrupt/unsupported bytes.
    return src;
  }
  final ui.FrameInfo frame;
  try {
    frame = await codec.getNextFrame();
  } catch (_) {
    codec.dispose();
    return src;
  }
  final image = frame.image;
  final int width = image.width;
  final int height = image.height;
  final ByteData? raw;
  try {
    raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  } finally {
    image.dispose();
    codec.dispose();
  }
  if (raw == null) return src;
  return ThumbEncoder.instance.encode(
    raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
    width,
    height,
  );
}

/// Pure Dart JPEG encode of straight RGBA pixels (quality 80). Runs on the
/// helper isolate; no engine access, so it behaves identically anywhere.
Uint8List encodeRgbaToJpeg(Uint8List rgba, int width, int height) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

/// One long-lived isolate that JPEG-encodes raw frames. Spawned on first use;
/// if it cannot be spawned, dies, or fails on a frame, the call falls back to
/// `compute` so a thumbnail is never lost to the helper.
class ThumbEncoder {
  ThumbEncoder._();
  static final ThumbEncoder instance = ThumbEncoder._();

  Isolate? _isolate;
  SendPort? _send;
  ReceivePort? _receive;
  Future<void>? _starting;
  int _nextId = 0;
  final Map<int, Completer<Uint8List?>> _pending = {};

  Future<Uint8List> encode(Uint8List rgba, int width, int height) async {
    try {
      await (_starting ??= _spawn().whenComplete(() => _starting = null));
      final send = _send;
      if (send != null) {
        final id = _nextId++;
        final done = Completer<Uint8List?>();
        _pending[id] = done;
        send.send([id, TransferableTypedData.fromList([rgba]), width, height]);
        final bytes = await done.future;
        if (bytes != null) return bytes;
      }
    } catch (_) {
      // fall through to compute
    }
    return compute(_encodeOnce, _RawFrame(rgba, width, height));
  }

  Future<void> _spawn() async {
    if (_send != null) return;
    final receive = ReceivePort();
    final ready = Completer<SendPort>();
    receive.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message == null) {
        _onExit(receive); // onExit notification
      } else if (message is List && message.length == 2) {
        final done = _pending.remove(message[0] as int);
        final data = message[1];
        done?.complete(
          data is TransferableTypedData ? data.materialize().asUint8List() : null,
        );
      }
    });
    try {
      final isolate = await Isolate.spawn(
        _encoderMain,
        receive.sendPort,
        errorsAreFatal: false,
        onExit: receive.sendPort,
      );
      final send = await ready.future.timeout(const Duration(seconds: 10));
      _isolate = isolate;
      _receive = receive;
      _send = send;
    } catch (_) {
      receive.close();
      rethrow;
    }
  }

  void _onExit(ReceivePort port) {
    if (!identical(_receive, port)) return;
    port.close();
    _receive = null;
    _send = null;
    _isolate = null;
    final pending = Map.of(_pending);
    _pending.clear();
    for (final c in pending.values) {
      c.complete(null); // callers fall back to compute
    }
  }

  /// Stops the helper isolate (tests).
  @visibleForTesting
  void shutdownForTesting() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _send = null;
    _receive?.close();
    _receive = null;
    final pending = Map.of(_pending);
    _pending.clear();
    for (final c in pending.values) {
      c.complete(null);
    }
  }
}

class _RawFrame {
  const _RawFrame(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width;
  final int height;
}

Uint8List _encodeOnce(_RawFrame f) => encodeRgbaToJpeg(f.rgba, f.width, f.height);

void _encoderMain(SendPort main) {
  final port = ReceivePort();
  main.send(port.sendPort);
  port.listen((message) {
    final list = message as List;
    final id = list[0] as int;
    try {
      final rgba = (list[1] as TransferableTypedData).materialize().asUint8List();
      final jpeg = encodeRgbaToJpeg(rgba, list[2] as int, list[3] as int);
      main.send([id, TransferableTypedData.fromList([jpeg])]);
    } catch (_) {
      main.send([id, null]);
    }
  });
}
