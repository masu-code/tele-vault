# Vendored `tg`

Upstream: https://github.com/telegramflutter/tg, version 0.0.20, MIT (see LICENSE, (c) 2020-2026 Mahdi K. Fard).
Vendored on 2026-11-09 into TeleVault to fix hot paths (per-block AES key schedule, per-block allocations,
List<int> spreads, removeRange receive buffer) and a predictable RNG. Pub's `tg` is replaced by this path dependency.

## Modifications (running list)
- pubspec: version 0.0.20+televault.1, publish_to none, added `crypto: ^3.0.0`.
- T1.0 (2026-11-11): pubspec `environment.sdk` raised to `>=3.0.0 <4.0.0` (needed for `TgInternals`: abstract final class + record
  return type); analysis_options.yaml disables `use_super_parameters` and `unnecessary_library_name` (they only fire at language 3.0;
  upstream sources stay verbatim).
- T1.0: `lib/src/internals.dart` (new `part`, `TgInternals`: test/bench hooks, NOT public API) and `part 'src/internals.dart';` in `tg.dart`.
- T1.0: `lib/src/encoders.dart`: pure refactor, `_encodeWithAuth` computes padding then calls new
  `_encodeWithAuthPadded(message, m, sessionId, auth, padding)` (byte-identical output; the message is serialized twice until T1.3).
- T1.1/T1.2 (2026-11-11): new files only, not wired in: `lib/src/crypto/*` (`TgCryptoBackend`, `TgCrypto.backend`,
  pure-Dart AES/IGE/CTR/SHA-256) and `lib/src/io/*` (`FastBinaryReader`, `ByteSink`, `RecvBuffer`).
- T1.3 (2026-11-11), transport integrated with the new code. Public API unchanged (see "API" below).
  - `tg.dart`: imports `src/crypto/backend.dart` and `src/io/{byte_sink,fast_binary_reader,recv_buffer}.dart`; the unused
    `src/encrypt.dart` import is dropped (file kept, `AesEcb` no longer used).
  - `private.dart`: `_aesIgeEncryptDecrypt` delegates to `TgCrypto.backend.aesIge` (views supported; the original read
    `input.buffer` as Int64 words). New `_messageKeyIv` (x1/x2 as two 52-byte regions of one scratch buffer, two backend
    sha256, scratch zeroed), `_cryptMessageInPlace` (in-place IGE, derived key/iv zeroed after use) and `_asBytes`.
    `_encryptDecryptMessage` keeps its signature and returns a new buffer through them.
  - `auth_key.dart`: library-private `late final Uint8List _keyBytes` (key as Uint8List, built once).
  - `encoders.dart`: `_plainFrame` builds unencrypted frames in one Uint8List (ByteSink). `_encodeWithAuth` and
    `_encodeWithAuthPadded` share `_encodeWithAuthImpl`: serialize once into a ByteSink laid out as
    `authKey[88:120] | salt | session | msgId | seqno | len | msg | padding`, sha256 over it, header written over [4,32),
    IGE in place from offset 32; the returned frame is a view at offset 4 (IGE data at frame offset 28; [0,4) zeroed).
    Size hint for `UploadSaveFilePart`/`UploadSaveBigFilePart` avoids sink growth. `_XInt.asUint64List/asUint32List` removed
    from `extensions.dart` (unused).
  - `decoders.dart`: both transformers use `RecvBuffer` (CTR on the 4 length bytes once, then the body in `_Frame.parse`).
    Raw-stream errors are forwarded and its end closes the output stream (originally neither). `_EncryptedTransformer`
    exposes `frames` (`_Frame`, with the server msg_id) for the client; `stream` maps it to messages.
  - `frame.dart`: `_Frame.parse` runs CTR and IGE in place on the frame (decrypt from offset 24), reads with
    `FastBinaryReader`; unencrypted payload read through a view. `toUint8List` uses `_plainFrame`, CTR in place.
  - `obfuscation.dart`: `AesCtr` is backed by `TgCrypto.backend.createCtr` (pointycastle kept only for non-32-byte keys);
    Uint8List with `length == input.length` is processed in place, otherwise the original copy semantics (keystream advances
    by `input.length`, only `length` bytes written back). `Obfuscation.random` regenerates until the preamble is valid
    (`_isValidObfuscationRandom`: byte0 != 0xEF; LE u32 at 0 not in {HEAD, POST, GET , OPTI, 16030102, DDDDDDDD, EEEEEEEE};
    u32 at 4 != 0).
  - RNG (security): `_rng = Random.secure()`; `_Random.getBytes` writes real random bytes (was `(i + 1) % 256`); `dh.dart`
    `_pqFactorize` uses `Random.secure()`. Every auth key created before this change was negotiated with constant DH
    randomness: re-login required (plan section 10).
  - `client.dart`: `Pong` completes the pending call whose msg_id == `pong.msgId`; new `Future<void> ping()`;
    new `void failAllPending(Object error)`, called automatically with the error when the receive stream errors and with
    `StateError('tg: connection closed')` when it ends (later `invoke`s then fail with that StateError at once); pending
    entries older than 5 min are dropped on each invoke (completed with `TimeoutException`); a send failure removes its
    pending entry; unacked server messages get a standalone `MsgsAck` after 10 s without a request carrying acks;
    `BadMsgNotification` 16/17 sets `idGenerator.serverTicksOffset` from the server msg_id of the notification and resends
    the call once (17 also resets the generator's last id so the next id follows the corrected clock); internal resends
    (BadServerSalt, 16/17) route send errors to the caller instead of an unhandled future. GzipPacked parsed with
    `FastBinaryReader`.
  - `internals.dart`: `encodeWithAuthRandomPadding`, `obfuscationRandomIsValid` (test hooks); `parseFrame` now modifies
    its input (in-place decrypt).
  - Tests: `golden_test.dart`, `round_trip_test.dart`, `obfuscation_random_test.dart`, `client_liveness_test.dart`.
    `tool/bench.dart`: labels "new", SHA-256 row for the backend.
  - API: additions only (`Client.ping`, `Client.failAllPending`, `TgInternals` hooks); no signature removed or changed.
- T2.2 (2026-11-11), native crypto backend.
  - pubspec: path dependency `tv_crypto: ../tv_crypto` (FFI, library built by its hook; run tools that need it with
    `dart test` / `dart run` / `dart build cli`, not `dart compile exe`).
  - `lib/src/crypto/native_backend.dart` (new): `NativeCryptoBackend` (name `native`, zero-copy views at any offset,
    in-place IGE), `NativeCryptoBackend.tryCreate()`, `crossCheckBackend()` (IGE enc/dec, CTR split 5+50+25, SHA-256
    vs `DartCryptoBackend` on fixed vectors, unaligned views; never throws) and `selectCryptoBackend()`.
  - `lib/src/crypto/backend.dart`: `TgCrypto.backend` is now a getter/setter. Default resolved lazily once per isolate:
    native only if `bool.fromEnvironment('TV_NATIVE_CRYPTO', defaultValue: true)`, `TvCrypto.tryLoad()` succeeds and
    the cross-check passes; else Dart. Prints one line `TVDIAG: tg crypto backend=<name>/<info>` (`<info>` = tv_crypto
    info bits in hex, `off` when disabled by the define, `none` when the library does not load). `resetForTesting()`
    drops an installed backend and returns to the resolved default (no second resolution or log line).
  - Tests: `backend_parity_test.dart` (selection, cross-check rejects broken backends, native vs Dart parity with
    views at 0/1/4/24/32 and in place, accelerated and forced-portable); `golden_test.dart` and `round_trip_test.dart`
    run every test under both backends; `crypto_aes_test.dart` adjusted to the lazy default (its SHA group uses
    `DartCryptoBackend` directly).
  - `tool/bench.dart`: "new" paths measured under both backends (columns dart / native); compiled with `dart build cli`.
- T1.4 (2026-11-11), incoming msg_key verification (security). New public const `kVerifyIncomingMsgKey = true` (`frame.dart`).
  - `frame.dart`: `_Frame.parse` first requires `data.length - 24 >= 32` and a multiple of 16, decrypts, then (if the const is
    set) checks `sha256(authKey[96:128] || plaintext)[8:24] == msg_key` (constant-time compare, scratch zeroed), `32 + msg_len <=
    plaintext.length` (msg_len read unsigned) and padding 12..1024. Failures throw the library-private `_FrameDropped(reason)`.
  - `decoders.dart`: `_EncryptedTransformer._readFrame` catches per frame (any exception, not only `_FrameDropped`), logs exactly
    one line `TVDIAG: tg dropped frame: <reason>` (reasons: `msg_key mismatch`, `bad msg_len`, `bad padding length`, `bad frame
    length`, or `parse error (<runtimeType>)`; never bytes) with `print`, and continues with the next frame (CTR already advanced
    past the dropped body; its msgId is not acked). The unencrypted transformer is unchanged.
  - `TgInternals.parseFrame` now throws `_FrameDropped` for such frames (use the receivers for the drop behavior).
  - Test: `test/msg_key_test.dart`.
- F2 (2026-11-11), the encrypted channel only accepts frames under its own auth key (security). `_Frame.parse` takes optional
  `expectedAuthKeyId` / `expectedSessionId`; `_EncryptedTransformer` passes its key id (always) and the client's session id
  (`Client` passes `_sessionId`, now readable as `Client.sessionId`). After the CTR pass, a frame with another auth_key_id is
  dropped as `unencrypted` (id 0: plaintext frames have no msg_key, so anyone who saw the preamble could inject e.g.
  BadMsgNotification 16) or `foreign auth_key_id`; a verified frame of another session as `foreign session_id`. The
  unencrypted (handshake) transformer and `TgInternals.parseFrame` pass neither and are unchanged; `TgInternals.encryptedReceiver`
  takes an optional `sessionId`. Tests: `test/msg_key_test.dart`, `test/client_liveness_test.dart` (the fake server now uses the
  client's session id).

## Reference copy and golden fixture
- `tool/reference/tg_0_0_20_reference.dart`: frozen verbatim copy of the original crypto/transport code renamed `ref*`. Never optimize it.
- `test/goldens/tg_0_0_20_goldens.json` is generated ONCE from the unmodified code (T1.0, `tool/gen_goldens.dart`, which refuses to
  overwrite it) and must never be regenerated. `test/reference_matches_original_test.dart` checks its sha256 against the line below.
sha256: 42ebbd1e7925cf1263a9fc75310665d5dbd25382aece7a790f7d7b4808982c16

## Bench, T1.3 (AOT, reference vs new, Dart backend)
`dart compile exe tool/bench.dart` (gen_snapshot takes ~8 min here), run on the dev PC (Windows 11, 8 cores) on 2026-11-11,
CPU load 7 % before / 4 % after (idle machine). MB/s = 2^20 bytes/s, median of timed runs.

| Path | reference (tg 0.0.20) | new (T1.3) | ratio |
|---|---:|---:|---:|
| AES-IGE encrypt 1 MiB | 4.86 | 59.99 | 12.3x |
| AES-IGE decrypt 1 MiB | 3.18 | 52.42 | 16.5x |
| AES-CTR 1 MiB (16 KiB chunks) | 10.04 | 59.97 | 6.0x |
| SHA-256 1 MiB | 15.17 | 105.22 | 6.9x |
| encode 512 KiB UploadSaveFilePart (no CTR) | 2.56 | 38.18 | 14.9x |
| receive 1 MiB UploadFile frame (64 KiB chunks, CTR + IGE + TL) | 1.91 | 25.77 | 13.5x |

Note: the bench used a fixed 80-byte padding that makes `32 + len + pad` not a multiple of 16; the original code accepted
it, the new IGE rejects it (ArgumentError). The bench now computes a valid padding (production padding was always valid).

## Bench, T2.2 (AOT, Dart vs native backend)
`dart build cli -t tool/bench.dart -o <dir>` (~8 min), run on the dev PC (Windows 11, 8 cores, AES-NI) on 2026-11-11,
CPU load 9 % before / 9 % after. tv_crypto info `0x03` (AES-NI active, no SHA acceleration on x64). Same method as above.
The receive row includes T1.4's msg_key check (one extra SHA-256 over the plaintext), hence Dart below the T1.3 number.

| Path | reference (tg 0.0.20) | new, Dart backend | new, native backend | native / Dart |
|---|---:|---:|---:|---:|
| AES-IGE encrypt 1 MiB | 4.84 | 56.94 | 813.01 | 14.3x |
| AES-IGE decrypt 1 MiB | 3.14 | 53.91 | 812.35 | 15.1x |
| AES-CTR 1 MiB (16 KiB chunks) | 9.79 | 56.60 | 2331.00 | 41.2x |
| SHA-256 1 MiB | 14.83 | 104.91 | 248.45 | 2.4x |
| encode 512 KiB UploadSaveFilePart (no CTR) | 2.58 | 36.39 | 184.43 | 5.1x |
| receive 1 MiB UploadFile frame (64 KiB chunks, CTR + IGE + SHA + TL) | 1.91 | 18.92 | 82.41 | 4.4x |
