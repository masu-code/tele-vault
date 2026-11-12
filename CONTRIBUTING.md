# Contributing to TeleVault

Thanks for your interest. Issues and pull requests are welcome.

## Before you start

- Open an issue first for anything larger than a small fix, so we can agree on the approach.
- Never include real Telegram credentials, session data, phone numbers or personal media in issues, logs, screenshots or tests. Use synthetic data.

## Setup

Install the Flutter version pinned in `.github/workflows/ci.yml` (currently 3.44.2, stable), then:

```bash
flutter pub get
```

See "Build from source" in the [README](README.md) for the native toolchain needed by `packages/tv_crypto`.

## Commit messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<optional scope>): <summary>
```

Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`. Mark breaking changes with `!` or a `BREAKING CHANGE:` footer. Examples:

```
feat(gallery): add month fast-scroll bubble
fix(index): never save an empty index after a failed marker search
```

Versions follow [Semantic Versioning](https://semver.org/). User-visible changes go in `CHANGELOG.md` under `[Unreleased]`.

## Running the checks

Run these before opening a pull request; CI runs the same ones.

```bash
# App (repository root)
flutter analyze lib
flutter test

# Vendored MTProto library
cd packages/tg
dart test
```

The analyzer currently reports a handful of `info` level hints; new code should not add any. `packages/tv_core` and `packages/tv_crypto` have their own `dart test` suites as well.

## Vendored code

- `packages/tg` is a fork of [`tg`](https://github.com/telegramflutter/tg) 0.0.20. Read `packages/tg/VENDORED.md` before editing it, and do not modify the frozen reference copy or the golden fixture it describes.
- Changes to the crypto path (`packages/tg`, `packages/tv_crypto`) need tests that run against both the Dart and the native backend.
