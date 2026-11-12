import 'dart:typed_data';

import 'aes256.dart';
import 'backend.dart';

/// AES-256-CTR with a 128-bit big-endian counter (wraps from ff..ff to 0) and
/// a keystream that continues byte-wise across calls. Equivalent to
/// pointycastle's `AES/CTR`.
final class DartCtrStream implements TgCtrStream {
  DartCtrStream(Uint8List key32, Uint8List iv16) : _aes = Aes256(key32) {
    if (iv16.length != 16) {
      throw ArgumentError.value(iv16.length, 'iv16.length', 'must be 16');
    }
    _ctr.setRange(0, 16, iv16);
  }

  final Aes256 _aes;
  final Uint8List _ctr = Uint8List(16);
  late final Uint32List _ctrW = _ctr.buffer.asUint32List();
  final Uint8List _ks = Uint8List(16);
  late final Uint32List _ksW = _ks.buffer.asUint32List();
  int _pos = 16; // keystream bytes already consumed; 16 = need a new block
  bool _disposed = false;

  void _nextBlock() {
    _aes.encryptBlock(_ctrW, 0, _ksW, 0);
    for (var k = 15; k >= 0; k--) {
      final v = (_ctr[k] + 1) & 0xFF;
      _ctr[k] = v;
      if (v != 0) break;
    }
    _pos = 0;
  }

  @override
  void process(Uint8List data, int offset, int length) {
    if (_disposed) throw StateError('CTR stream disposed');
    RangeError.checkValidRange(offset, offset + length, data.length);
    var i = offset;
    final end = offset + length;
    // Rest of the current keystream block.
    while (_pos < 16 && i < end) {
      data[i++] ^= _ks[_pos++];
    }
    var blocks = (end - i) >> 4;
    if (blocks > 0) {
      final abs = data.offsetInBytes + i;
      if ((abs & 3) == 0) {
        final wd = data.buffer.asUint32List(abs, blocks * 4);
        final ks = _ksW;
        for (var j = 0; j < wd.length; j += 4) {
          _nextBlock();
          wd[j] ^= ks[0];
          wd[j + 1] ^= ks[1];
          wd[j + 2] ^= ks[2];
          wd[j + 3] ^= ks[3];
        }
        i += blocks * 16;
        _pos = 16;
      } else {
        while (blocks-- > 0) {
          _nextBlock();
          for (var k = 0; k < 16; k++) {
            data[i + k] ^= _ks[k];
          }
          i += 16;
          _pos = 16;
        }
      }
    }
    if (i < end) {
      _nextBlock();
      while (i < end) {
        data[i++] ^= _ks[_pos++];
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _aes.wipe();
    _ctr.fillRange(0, 16, 0);
    _ks.fillRange(0, 16, 0);
  }
}
