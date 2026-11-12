import 'dart:async';
import 'dart:io' show ProcessInfo;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Debug/profile-only performance counters (compiled out of release builds by
/// the [kReleaseMode] guard in every mutator and in [startMonitoring]).
///
/// Privacy: only counts and timings live here. Never record names, paths,
/// captions, album names or thumbnails. Screen names passed to [screenBuild]
/// are code identifiers ("gallery", "albums"), never user data.
///
/// The counters are bumped by the code under measurement (tile, screens,
/// transport); this class only defines them, plus the frame-timing listener and
/// the event-loop watchdog that a perf test installs with [startMonitoring].
abstract final class TvStats {
  /// False in release builds, where every hook below is a no-op.
  static const bool enabled = !kReleaseMode;

  // --- counters bumped by instrumented code (plain fields: cheap, settable) ---

  /// A tile was painted with no colour, no preview and no image.
  static int tileBlankFrames = 0;

  /// A gallery tile `build` ran.
  static int tileBuilds = 0;

  /// Builds per screen/widget name (see class doc for allowed names).
  static final Map<String, int> screenBuilds = <String, int>{};

  /// Reconnects triggered by a failed idle probe in `TelegramService.call`.
  static int rpcProbeReconnects = 0;

  // --- derived by the monitors ---

  /// Event-loop stalls longer than 32 ms seen by the watchdog timer.
  static int longTasksOver32ms = 0;

  /// Longest UI-isolate task in ms: max of the watchdog stall and the longest
  /// frame `build` phase.
  static double longestUiTaskMs = 0;

  // --- hooks ---

  static void tileBuild() {
    if (!kReleaseMode) tileBuilds++;
  }

  static void tileBlank() {
    if (!kReleaseMode) tileBlankFrames++;
  }

  static void screenBuild(String name) {
    if (!kReleaseMode) screenBuilds[name] = (screenBuilds[name] ?? 0) + 1;
  }

  static void rpcProbeReconnect() {
    if (!kReleaseMode) rpcProbeReconnects++;
  }

  // --- monitoring (installed by perf tests) ---

  static final List<double> _buildMs = <double>[];
  static final List<double> _rasterMs = <double>[];
  static final List<double> _totalMs = <double>[];
  static final Stopwatch _clock = Stopwatch();
  static Timer? _watchdog;
  static int _lastTickUs = 0;
  static int _watchdogMs = 16;
  static bool _listening = false;
  static int _peakRssBytes = 0;

  /// Zeroes every counter and the collected frame timings.
  static void reset() {
    tileBlankFrames = 0;
    tileBuilds = 0;
    screenBuilds.clear();
    rpcProbeReconnects = 0;
    longTasksOver32ms = 0;
    longestUiTaskMs = 0;
    _buildMs.clear();
    _rasterMs.clear();
    _totalMs.clear();
    _peakRssBytes = 0;
  }

  /// Installs the frame-timing listener and the stall watchdog. Idempotent.
  /// No-op in release builds.
  static void startMonitoring({Duration watchdogInterval = const Duration(milliseconds: 16)}) {
    if (kReleaseMode) return;
    if (!_listening) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _listening = true;
    }
    _watchdog?.cancel();
    _watchdogMs = watchdogInterval.inMilliseconds;
    _clock
      ..reset()
      ..start();
    _lastTickUs = 0;
    _watchdog = Timer.periodic(watchdogInterval, (_) {
      final now = _clock.elapsedMicroseconds;
      final gapMs = (now - _lastTickUs) / 1000.0;
      _lastTickUs = now;
      final stallMs = gapMs - _watchdogMs;
      if (stallMs > 32) longTasksOver32ms++;
      if (stallMs > longestUiTaskMs) longestUiTaskMs = stallMs;
      final rss = ProcessInfo.currentRss;
      if (rss > _peakRssBytes) _peakRssBytes = rss;
    });
  }

  /// Removes the listener and the watchdog; the collected data stays readable
  /// through [snapshot] until the next [reset].
  static void stopMonitoring() {
    if (_listening) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _listening = false;
    }
    _watchdog?.cancel();
    _watchdog = null;
    _clock.stop();
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds / 1000.0;
      _buildMs.add(build);
      _rasterMs.add(t.rasterDuration.inMicroseconds / 1000.0);
      _totalMs.add(t.totalSpan.inMicroseconds / 1000.0);
      if (build > longestUiTaskMs) longestUiTaskMs = build;
      if (build > 32) longTasksOver32ms++;
    }
  }

  static double _pct(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final rank = (p * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }

  static Map<String, num> _dist(List<double> values) {
    final s = [...values]..sort();
    num r(double v) => (v * 100).round() / 100;
    return {
      'p50': r(_pct(s, 0.50)),
      'p90': r(_pct(s, 0.90)),
      'p99': r(_pct(s, 0.99)),
      'max': r(s.isEmpty ? 0 : s.last),
    };
  }

  /// JSON-serialisable numbers only.
  static Map<String, dynamic> snapshot() {
    final frames = _totalMs.length;
    final slow16 = _totalMs.where((v) => v > 16.7).length;
    final slow32 = _totalMs.where((v) => v > 32).length;
    final rss = ProcessInfo.currentRss;
    return <String, dynamic>{
      'tileBlankFrames': tileBlankFrames,
      'tileBuilds': tileBuilds,
      // tileBuilds == 0 means no tile hook is installed: tileBlankFrames is
      // then NOT a measurement.
      'tileHooksActive': tileBuilds > 0,
      'screenBuilds': Map<String, int>.of(screenBuilds),
      'rpcProbeReconnects': rpcProbeReconnects,
      'longTasksOver32ms': longTasksOver32ms,
      'longestUiTaskMs': (longestUiTaskMs * 100).round() / 100,
      'frames': frames,
      'framesOver16_7ms': slow16,
      'framesOver32ms': slow32,
      'jankyPct': frames == 0 ? 0 : (slow16 * 10000 / frames).round() / 100,
      'buildMs': _dist(_buildMs),
      'rasterMs': _dist(_rasterMs),
      'totalSpanMs': _dist(_totalMs),
      'rssMb': (rss / (1 << 20) * 10).round() / 10,
      'peakRssMb': ((rss > _peakRssBytes ? rss : _peakRssBytes) / (1 << 20) * 10).round() / 10,
    };
  }
}
