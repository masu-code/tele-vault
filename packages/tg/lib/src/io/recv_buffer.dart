// Receive-side reassembly buffer for length-prefixed MTProto transport frames
// (replaces `List<int>` + take/skip/removeRange, which was O(n) per frame).
import 'dart:typed_data';

class RecvBuffer {
  RecvBuffer([int initialCapacity = 16 * 1024])
      : _buf = Uint8List(initialCapacity < 16 ? 16 : initialCapacity);

  /// Capacity above which an emptied buffer is released.
  static const int _shrinkAbove = 4 * 1024 * 1024;

  Uint8List _buf;
  int _start = 0;
  int _end = 0;
  int? _frameLength;

  /// Bytes buffered and not yet taken (including the 4 length bytes).
  int get length => _end - _start;

  /// Appends [chunk].
  void add(List<int> chunk) {
    final n = chunk.length;
    if (n == 0) return;
    _ensureTail(n);
    _buf.setRange(_end, _end + n, chunk);
    _end += n;
  }

  void _ensureTail(int n) {
    if (_end + n <= _buf.length) return;
    final live = _end - _start;
    if (live + n <= _buf.length) {
      // Enough room once the consumed prefix is dropped.
      _buf.setRange(0, live, _buf, _start);
    } else {
      var cap = _buf.length * 2;
      if (cap < live + n) cap = live + n;
      final next = Uint8List(cap);
      next.setRange(0, live, _buf, _start);
      _buf = next;
    }
    _start = 0;
    _end = live;
  }

  /// Length of the next frame (little-endian int32 in the first 4 buffered
  /// bytes), or null while fewer than 4 bytes are buffered.
  ///
  /// The 4 bytes are copied and handed to [decryptCopy], which must decrypt
  /// them in place (this advances the obfuscation keystream exactly once; the
  /// result is cached until [takeFrame]). The buffered bytes stay untouched.
  int? peekLengthDecrypted(void Function(Uint8List four) decryptCopy) {
    final cached = _frameLength;
    if (cached != null) return cached;
    if (length < 4) return null;
    final four =
        Uint8List.fromList(Uint8List.sublistView(_buf, _start, _start + 4));
    decryptCopy(four);
    return _frameLength = ByteData.sublistView(four).getInt32(0, Endian.little);
  }

  /// Removes the 4 length bytes plus [length] body bytes and returns a copy of
  /// the body, or null if the whole frame is not buffered yet.
  Uint8List? takeFrame(int length) {
    if (length < 0) throw ArgumentError.value(length, 'length');
    if (this.length < 4 + length) return null;
    final from = _start + 4;
    final out =
        Uint8List.fromList(Uint8List.sublistView(_buf, from, from + length));
    _start = from + length;
    _frameLength = null;
    if (_start == _end) {
      _start = _end = 0;
      if (_buf.length > _shrinkAbove) _buf = Uint8List(16 * 1024);
    }
    return out;
  }
}
