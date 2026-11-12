// Native crypto throughput: `dart run tool/bench_native.dart`.
// Prints MB/s (1 MB = 1e6 bytes) for IGE enc/dec, CTR and SHA-256 over
// 1 MiB buffers, for the portable and the accelerated path. No user data.
// ignore_for_file: avoid_print
import 'dart:math';
import 'dart:typed_data';

import 'package:tv_crypto/tv_crypto.dart';

const int _size = 1 << 20;
const Duration _minTime = Duration(milliseconds: 700);

double _mbps(void Function() op) {
  for (var i = 0; i < 3; i++) {
    op(); // warm-up
  }
  final sw = Stopwatch()..start();
  var iters = 0;
  while (sw.elapsed < _minTime) {
    op();
    iters++;
  }
  sw.stop();
  return iters * _size / (sw.elapsedMicroseconds / 1e6) / 1e6;
}

void main() {
  final c = TvCrypto.tryLoad();
  if (c == null) {
    print('native: unavailable');
    return;
  }
  final r = Random(1);
  Uint8List rnd(int n) =>
      Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  final key = rnd(32);
  final iv = rnd(32);
  final data = rnd(_size);
  final out = Uint8List(_size);
  final digest = Uint8List(32);

  print('tv_crypto info=0x${c.info.toRadixString(16)}');
  for (final portable in [true, false]) {
    c.forcePortableForTesting(portable);
    final label = portable
        ? 'portable'
        : (c.aesAccelerated ? 'accelerated' : 'accelerated(n/a)');
    final igeEnc = _mbps(
      () => c.aesIge(
        encrypt: true,
        key32: key,
        iv32: iv,
        input: data,
        inOffset: 0,
        length: _size,
        output: out,
        outOffset: 0,
      ),
    );
    final igeDec = _mbps(
      () => c.aesIge(
        encrypt: false,
        key32: key,
        iv32: iv,
        input: data,
        inOffset: 0,
        length: _size,
        output: out,
        outOffset: 0,
      ),
    );
    final ctr = c.createCtr(key, Uint8List.sublistView(iv, 0, 16));
    final ctrMbps = _mbps(() => ctr.process(out, 0, _size));
    ctr.dispose();
    final sha = _mbps(() => c.sha256(data, 0, _size, digest));
    print(
      '$label: IGE enc ${igeEnc.toStringAsFixed(1)} MB/s, '
      'IGE dec ${igeDec.toStringAsFixed(1)} MB/s, '
      'CTR ${ctrMbps.toStringAsFixed(1)} MB/s, '
      'SHA-256 ${sha.toStringAsFixed(1)} MB/s'
      '${!portable && !c.shaAccelerated ? ' (SHA portable)' : ''}',
    );
  }
  c.forcePortableForTesting(false);
}
