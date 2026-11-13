# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.1] - 2026-11-13

### Added
- Log out from the account sheet. It ends the session on Telegram, clears local session data and keeps the upload registry for the same account.
- The app detects a session revoked from another device and returns to sign-in.
- Automatic background maintenance, with no manual buttons:
  - thumbnail packs are built from local thumbnails on Wi-Fi, with coverage read from existing packs so nothing is packed twice;
  - capture dates are recovered from EXIF and MP4 metadata;
  - old items without thumbnails are backfilled on Wi-Fi while charging.
- A read-only maintenance status line in the account sheet.
- Fullscreen toggle and tap-to-seek in the video player.
- Demo-mode screenshots in the README and on the landing page.

### Changed
- Pinch-to-zoom now uses `photo_view`. It works at any finger angle, and the photo can be zoomed while the full-resolution image is still loading.
- Telegram requests are paced adaptively: a shared flood gate, and an adaptive number of concurrent thumbnail downloads, with visible tiles first.
- Videos are decoded in hardware (`mediacodec-copy`, with an automatic fallback).
- Larger month titles in the gallery; Telegram-blue seek bar with a larger touch area.
- New app icon and the app name "TeleVault".

### Fixed
- The gallery no longer rebuilds every tile when an upload finishes.
- Long videos failing on the first open: file references are refreshed, a timeout retries once, and concurrent downloads of the same file are shared.
- Photos reordering after "Free up space": the capture date is stored before any device copy is deleted.
- Gallery sections now group by the date a photo was taken, not the upload date.
- Local index backups keep one per day for the last 7 days.

## [0.9.0] - 2026-11-12

First public pre-release.

### Added

- Unified gallery of device and cloud photos and videos, grouped by month, with instant previews (ThumbHash placeholders and a local thumbnail store) so tiles are never grey.
- Background backup of device photos and albums, with a progress notification, running with the app open or closed (WorkManager) and gated by Wi-Fi or mobile data.
- Deduplication: uploads are matched against the cloud index by original name and exact size, so reinstalling the app does not re-upload what is already stored.
- Index stored as a document in your own Telegram Saved Messages, so it survives reinstalls and is shared across devices.
- Native AES-256-IGE, AES-256-CTR and SHA-256 through FFI (`packages/tv_crypto`), using ARMv8 Crypto Extensions or AES-NI, with a portable fallback and a runtime cross-check against the pure Dart implementation.
- Thumbnail pack system and an in-app thumbnail backfill that builds previews for files already in the cloud.
- Video player with tap-to-seek, fullscreen and hardware decoding with a software fallback.
- Albums, archive and "Free up space" (only offers items confirmed in the synced index).
- File manager with folders, multi-select, upload and download, and transparent splitting and reassembly of files above Telegram's size limit.
- Bring-your-own Telegram API credentials: each install asks for its own `api_id` and `api_hash`; nothing is bundled.
- Vendored libraries: `packages/tg` (fork of `tg` 0.0.20, see `packages/tg/VENDORED.md`), `packages/tv_crypto` and `packages/tv_core` (pure Dart index models and codecs).
- Release signing configuration, GitHub Actions workflows for CI and tagged releases, and a project landing page.

### Changed

- MTProto transport reworked for speed: per-block key schedules and allocations removed, and a single-pass receive buffer. On a desktop benchmark, AES-IGE went from about 5 MB/s to about 800 MB/s with the native backend, and receiving a 1 MiB frame from about 1.9 MB/s to about 80 MB/s.
- Index reading, merging and writing moved off the UI isolate, with a local cache, conditional writes and three-way rebase of concurrent changes.
- Gallery tiles rebuilt in three layers with selection driven by value notifiers, removing rebuild storms and scroll jank. Albums and Files tabs load lazily.
- Viewer gestures handled by a screen-level pointer host instead of per-page recognizers, so taps and swipes work while pages animate; the scrim blur that caused transition jank was removed.
- Uploads and downloads run in dedicated isolates with inactivity timeouts, coalesced progress and atomic `.part` files.
- Upload registry moved to SQLite with a backup-first migration.
- Rate limiting (`FLOOD_WAIT`) is handled centrally with bounded retries, and the sync backs off after failures.
- Screen wake lock is no longer held permanently.

### Fixed

- Index forking after a reinstall that made most of the library disappear: the index is now found by its marker caption regardless of how deep it sits in Saved Messages, duplicated snapshots are merged, and a failed lookup raises an error instead of being treated as an empty library.
- Background backup that never ran because API credentials were not initialized in the headless engine.
- Duplicate uploads caused by a failed index save under `FLOOD_WAIT`: uploaded items are tracked durably until the index confirms them.
- Dead sockets hanging downloads, uploads and previews: liveness probing, fail-fast on closed connections, and bounded reconnects.
- A memory leak from racing futures against the socket-closed signal.
- Concurrent downloads of the same file corrupting each other.
- Stale "backed up" badge in device albums, and flicker when zooming into a photo.
- Photo permission is re-checked when the app returns to the foreground.

### Security

- Replaced the constant, predictable random byte generator inherited from upstream `tg` 0.0.20 with `Random.secure()`. Authorization keys created before this fix were negotiated with constant randomness and are not trustworthy: log in again and terminate old sessions from the official Telegram app.
- Incoming MTProto frames are now authenticated: the `msg_key` is verified in constant time, and length and padding are validated before parsing.
- Frames carrying a foreign `auth_key_id` or `session_id`, and unencrypted frames on the encrypted channel, are dropped, so a network observer cannot inject messages such as `BadMsgNotification`.
- Diagnostic logging no longer includes file names, paths, captions or frame contents.

[Unreleased]: https://github.com/masu-code/tele-vault/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/masu-code/tele-vault/releases/tag/v0.9.0
