// FFI bindings for the native tv_crypto library (src/tv_crypto.h).
//
// The asset id of this library is `package:tv_crypto/src/bindings.dart`
// (see hook/build.dart), which is the default asset id for `@Native` here.
// All calls are leaf calls: they never call back into Dart and run in
// bounded time, so `Uint8List.address` can be passed (zero copy).
import 'dart:ffi';

@Native<Uint32 Function()>(symbol: 'tvc_version', isLeaf: true)
external int tvcVersion();

@Native<Uint32 Function()>(symbol: 'tvc_info', isLeaf: true)
external int tvcInfo();

@Native<Void Function(Int32)>(symbol: 'tvc_force_portable', isLeaf: true)
external void tvcForcePortable(int on);

@Native<
  Int32 Function(
    Int32,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'tvc_aes256_ige', isLeaf: true)
external int tvcAes256Ige(
  int encrypt,
  Pointer<Uint8> key32,
  Pointer<Uint8> iv32,
  Pointer<Uint8> input,
  Pointer<Uint8> output,
  int length,
);

@Native<Size Function()>(symbol: 'tvc_aes256_ctr_ctx_size', isLeaf: true)
external int tvcAes256CtrCtxSize();

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>)>(
  symbol: 'tvc_aes256_ctr_init',
  isLeaf: true,
)
external int tvcAes256CtrInit(
  Pointer<Void> ctx,
  Pointer<Uint8> key32,
  Pointer<Uint8> iv16,
);

@Native<Void Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, Size)>(
  symbol: 'tvc_aes256_ctr_xor',
  isLeaf: true,
)
external void tvcAes256CtrXor(
  Pointer<Void> ctx,
  Pointer<Uint8> input,
  Pointer<Uint8> output,
  int length,
);

@Native<Void Function(Pointer<Uint8>, Size, Pointer<Uint8>)>(
  symbol: 'tvc_sha256',
  isLeaf: true,
)
external void tvcSha256(Pointer<Uint8> input, int length, Pointer<Uint8> out32);

@Native<
  Void Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size, Pointer<Uint8>)
>(symbol: 'tvc_sha256_2', isLeaf: true)
external void tvcSha256Two(
  Pointer<Uint8> a,
  int aLength,
  Pointer<Uint8> b,
  int bLength,
  Pointer<Uint8> out32,
);
