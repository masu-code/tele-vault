// Growable byte list for TL serialization: `TlObject.serialize(List<int>)` only
// calls add/addAll, which on a boxed `List<int>` costs one boxed element per
// byte. ByteSink stores bytes in a Uint8List and bulk-copies TypedData.
import 'dart:collection';
import 'dart:typed_data';

class ByteSink extends ListBase<int> {
  ByteSink([int initialCapacity = 256])
      : _buf = Uint8List(initialCapacity < 16 ? 16 : initialCapacity);

  Uint8List _buf;
  int _len = 0;

  @override
  int get length => _len;

  @override
  set length(int newLength) {
    if (newLength < 0) throw RangeError.value(newLength, 'length');
    if (newLength > _len) {
      reserve(newLength - _len);
      _buf.fillRange(_len, newLength, 0);
    }
    _len = newLength;
  }

  @override
  int operator [](int index) {
    if (index < 0 || index >= _len) throw RangeError.index(index, this);
    return _buf[index];
  }

  @override
  void operator []=(int index, int value) {
    if (index < 0 || index >= _len) throw RangeError.index(index, this);
    _buf[index] = value;
  }

  /// Ensures room for [additional] more bytes without another reallocation.
  void reserve(int additional) {
    final needed = _len + additional;
    if (needed <= _buf.length) return;
    var cap = _buf.length * 2;
    if (cap < needed) cap = needed;
    final next = Uint8List(cap);
    next.setRange(0, _len, _buf);
    _buf = next;
  }

  @override
  void add(int element) {
    if (_len == _buf.length) reserve(1);
    _buf[_len++] = element;
  }

  @override
  void addAll(Iterable<int> iterable) {
    if (iterable is List<int>) {
      // Typed data and plain lists both have a known length: one bulk copy.
      final n = iterable.length;
      reserve(n);
      _buf.setRange(_len, _len + n, iterable);
      _len += n;
    } else {
      for (final b in iterable) {
        add(b);
      }
    }
  }

  @override
  void clear() => _len = 0;

  /// Returns the written bytes as a view and detaches them: the sink is empty
  /// afterwards and further writes use a fresh buffer, so the returned view is
  /// never overwritten.
  Uint8List takeBytes() {
    final out = Uint8List.sublistView(_buf, 0, _len);
    _buf = Uint8List(256);
    _len = 0;
    return out;
  }
}
