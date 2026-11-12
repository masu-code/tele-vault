# TeleVault perf harness and baseline (M0)

Instruments built by T5.0. Device: Redmi Note 13, adb id `$env:TV_DEVICE`, package
`com.masucode.tele_vault`, **profile** build always. Numbers only: no
screenshots, no file names/paths/captions in any output. On-device runs only by
the main session and only with the owner's permission.

## Commands (from the project root)

```powershell
# 1. Crypto bench (no user data). Needs libtv_crypto.so in the build (hook) for
#    the native columns; without it the native columns say "unavailable".
tool/measure_device.ps1 -Test crypto_bench

# 2. Synthetic gallery, 6000 generated cloud-only items. Reads NO real data.
tool/measure_device.ps1 -Test synthetic_gallery -Impeller off
tool/measure_device.ps1 -Test synthetic_gallery -Impeller on
#    options: -KeepSynth (keep generated files for faster reruns),
#             -SynthN 6000, -ImageCacheItems 600 -ImageCacheMb 120

# 3. OPTIONAL, owner permission EVERY time: same script on the real library.
tool/measure_device.ps1 -Test real_timing -AllowReal
```

Raw drive equivalents (what the script runs):

```powershell
flutter drive --driver=test_driver/perf_driver.dart `
  --target=integration_test/synthetic_gallery_test.dart --profile -d $env:TV_DEVICE `
  [--enable-impeller | --no-enable-impeller] `
  --dart-define=TV_IMG_CACHE_ITEMS=600 --dart-define=TV_IMG_CACHE_MB=120
```

Outputs: `build/perf/<test>.json` (test report: TvStats, frame timings from
`watchPerformance` under key `frames`, per-phase numbers) and
`build/perf/<test>_device.txt` (gfxinfo janky %, 50/90/95/99th percentiles,
slow-UI counters, meminfo TOTAL PSS / Native Heap / Graphics).

## What each test does

- `crypto_bench_test`: MB/s of AES-IGE enc/dec 1 MiB, AES-CTR 1 MiB (16 KiB
  chunks), SHA-256 1 MiB, encode of a 512 KiB `UploadSaveFilePart`, receive of
  a 1 MiB `UploadFile` frame, for `ref` (frozen tg 0.0.20), `lib` (current
  `packages/tg/lib/src` through `TgInternals`), `nPort` (tv_crypto portable C)
  and `nAccel` (tv_crypto ARMv8 CE; only if active). Parity asserts (identical
  bytes across all implementations, IGE/CTR/SHA/msg_key) fail the test on any
  mismatch. Native "encode"/"receive" columns are the crypto-only pipeline
  built from tv_crypto primitives (no TL), an optimistic bound until T2.2.
  Gate A: phone native IGE >= 150 MB/s and parity OK.
- `synthetic_gallery_test`: `GalleryScreen` with `galleryFeedProvider`
  overridden by N=6000 generated cloud-only `FileItem` (ids `synth-NNNNN`,
  negative message ids, 40 months). Thumbs are generated JPEGs (256 px, colour +
  number) written to `<appSupport>/televault_thumbs/synth-*.jpg`; items 0..23
  also get a generated 1600x1200 JPEG in `<tmp>/televault_cache/synth-*/` so the
  viewer needs no network. `SharedPreferences` is an empty in-memory mock (real
  backup registry never read). The test fails if the Telegram client got
  connected. Generated files are deleted at the end (unless `-KeepSynth`).
  Script: 3 slow flings, 3 fast flings, settle 2 s, scrollbar drag to 50 %
  (settle), to 100 % (settle), jump to top (settle), open item 10, swipe 5
  pages, back. Wrapped in `watchPerformance`.
- `real_timing_test`: same scroll script on the real feed (no viewer), then
  tap-to-full-res for up to 4 on-device and 4 cloud-only photos from the first
  120 entries. Reports counters and ms only.

## Metrics: where each comes from

| Gate metric | Source |
|---|---|
| janky %, p50/p90/p99 frame ms | `build/perf/<test>_device.txt` (gfxinfo, authoritative, script window) and `tvStats.totalSpanMs` / `frames` in the JSON (in-process) |
| `longestUiTaskMs`, `longTasksOver32ms` | `tvStats` (16 ms watchdog + frame build phase) |
| `tileBlankFrames` | `tvStats.tileBlankFrames`, valid ONLY if `tvStats.tileHooksActive` is true (a tile build hook in `GalleryTile` bumps `TvStats.tileBuild()` / `tileBlank()`; added by T3.5). Until then 0 means "not measured". |
| tiles without a decoded image | `script.tiles`, `script.restChecks` (test-side tree walk; independent of hooks). `restChecks.*.withoutImage` must be 0 once settled. Note: a coloured preview painted instead of an image counts as "without image" here, so use it as an upper bound after T3.5 |
| PSS | `_device.txt` (`TOTAL PSS`, `Native Heap`, `Graphics`) |
| tap-to-full-res | `script.viewer.tapToFullResMs` (synthetic) / `tapToFullResMs.*` (real); -1 = timeout |

Sampling the tile tree every 250 ms costs a few ms per sample, so the in-test
frame numbers are slightly pessimistic; gfxinfo is the number to gate on.

## Impeller A/B

`-Impeller on|off` passes `--[no-]enable-impeller`. The manifest currently
disables Impeller; if the launch flag is ignored the script prints
`renderer: no Impeller line seen`. In that case flip the manifest meta-data
`io.flutter.embedding.android.EnableImpeller` for the run (main session). Keep
whichever is faster and visually correct (owner looks at the synthetic screen
only).

## Baseline M0 (fill in after W1, before behaviour changes)

Record the commit/zip snapshot name and the date. Every later gate compares to
these rows.

| Metric | M0 | Gate |
|---|---|---|
| crypto: ref IGE enc/dec MB/s (phone) |  | informative |
| crypto: native portable / accel IGE MB/s |  | accel >= 150 |
| synthetic, Impeller off: janky % / p90 / p99 |  | < 5 % / <= 16 / <= 32 ms |
| synthetic, Impeller on: janky % / p90 / p99 |  | same |
| synthetic: longestUiTaskMs / longTasksOver32ms |  | < 100 / - |
| synthetic: tile blank frames (hooks active?) |  | 0 |
| synthetic: rest tiles without image |  | 0 |
| synthetic: PSS after script |  | <= 350 MB and <= 70 % of M0 |
| synthetic: tapToFullResMs (cached file) |  | informative |
