import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;
import '../api_credentials_service.dart';
import '../download/download_worker.dart' show WorkerProgress;
import 'io_socket.dart';

final _floodWaitPattern = RegExp(r'FLOOD_WAIT_(\d+)');

/// If [errorMessage] contains a Telegram flood-wait error ("FLOOD_WAIT_5"),
/// the number of seconds to wait. Null for any other error.
int? floodWaitSecondsOf(String errorMessage) {
  final match = _floodWaitPattern.firstMatch(errorMessage);
  return match == null ? null : int.parse(match.group(1)!);
}

/// Thrown by [TelegramService.call] when Telegram asks to wait longer than
/// [TelegramService.maxFloodWaitSeconds], or still asks after the retries.
/// [toString] keeps `FLOOD_WAIT_N`, so it stays recognisable after crossing
/// an isolate boundary as text (see [FloodWaitException.tryParse]).
class FloodWaitException implements Exception {
  const FloodWaitException(this.seconds);
  final int seconds;

  static const _prefix = 'FloodWaitException: ';

  /// The exception [message] (an error that crossed an isolate as text)
  /// stands for, or null.
  static FloodWaitException? tryParse(String message) {
    if (!message.startsWith(_prefix)) return null;
    final s = floodWaitSecondsOf(message);
    return s == null ? null : FloodWaitException(s);
  }

  @override
  String toString() => '${_prefix}FLOOD_WAIT_$seconds';
}

/// Server errors that mean this session's authorization key was killed
/// (logged out from another device, terminated in Telegram's settings).
/// Only a hint: see [TelegramService.confirmRevocation], which probes before
/// anything is treated as a revocation, because AUTH_KEY_UNREGISTERED also
/// shows up as a sporadic one-off that a reconnect cures.
const _revocationErrors = {'AUTH_KEY_UNREGISTERED', 'SESSION_REVOKED'};

/// Whether [errorMessage] is one of [_revocationErrors].
bool isRevocationError(String errorMessage) =>
    _revocationErrors.any(errorMessage.startsWith);

/// Whether [text] (an error that crossed an isolate boundary as text, possibly
/// wrapped in an exception name) carries one of [_revocationErrors].
bool mentionsRevocation(String text) => _revocationErrors.any(text.contains);

/// Seed IPs used only to bootstrap the very first connection, before the
/// server's own data-center list is known. Production Telegram addresses; the
/// authoritative list arrives in the Config from initConnection and takes over
/// from there (see [_resolveDc]).
const _seedDcs = {
  1: (ip: '149.154.175.53', port: 443),
  2: (ip: '149.154.167.51', port: 443),
  3: (ip: '149.154.175.100', port: 443),
  4: (ip: '149.154.167.91', port: 443),
  5: (ip: '91.108.56.130', port: 443),
};

/// A saved session: which DC it belongs to plus the authorization key. The key
/// is DC-specific, so the DC id must travel with it.
class _Session {
  final int dcId;
  final tg.AuthorizationKey key;
  const _Session(this.dcId, this.key);
}

class TelegramService {
  TelegramService._();
  static final TelegramService instance = TelegramService._();

  tg.Client? _client;
  IoSocket? _socket;
  int _dcId = 2;

  /// The authorization key of the last successful [connect], kept apart from
  /// [_client] because every reconnect path nulls [_client] before its socket
  /// connect can fail. Without it one failed reconnect lost the key, and the
  /// next [call] reconnected with no key at all: a fresh handshake, a key the
  /// account never authorized, AUTH_KEY_UNREGISTERED on every request after.
  /// Cleared only by [clearSession] (logout / dead session).
  tg.AuthorizationKey? _lastKey;

  /// DC of the authenticated session (the one [saveSession] wrote or
  /// [restoreSession] read); null while there is no such session, e.g. during
  /// login, when the connection holds a key nothing authorized yet. Only an
  /// auth error on this DC can mean the session was revoked: this client has
  /// no file-DC / exported-authorization connections today, but a connection
  /// on any other DC (a login migration, or one added later) is expected to
  /// answer AUTH_KEY_UNREGISTERED until it is authorized there.
  int? _homeDcId;

  /// DC list reported by the server. Preferred over [_seedDcs] when present,
  /// since seed IPs can drift and only cover the common datacenters.
  List<t.DcOption> _dcOptions = [];

  tg.Client get client {
    final c = _client;
    if (c == null) throw StateError('Not connected. Call connect() first.');
    return c;
  }

  bool get isConnected => _client != null;

  /// Whether there is a connection worth reusing — connected AND its socket
  /// hasn't been killed underneath us (MIUI does that constantly). Login uses
  /// this to avoid re-handshaking on top of a perfectly good connection:
  /// [connect] always negotiates a brand-new authorization key, which throws
  /// away the one an in-flight phone code was issued against.
  bool get isUsable => _client != null && _socket?.isDead != true;

  /// Resolves a DC id to an address, preferring the server-reported list.
  ({String ip, int port}) _resolveDc(int dcId) {
    for (final o in _dcOptions) {
      if (o.id == dcId && !o.ipv6 && !o.cdn && !o.mediaOnly) {
        return (ip: o.ipAddress, port: o.port);
      }
    }
    final seed = _seedDcs[dcId];
    if (seed == null) throw StateError('Unknown DC $dcId');
    return seed;
  }

  /// Connects to [dcId] (or the current DC). When [authKey] is supplied the
  /// handshake is skipped and that key is reused (restored session).
  Future<tg.Client> connect({int? dcId, tg.AuthorizationKey? authKey}) async {
    final epoch = _sessionEpoch;
    // Drop whatever is currently open first. This used to just overwrite
    // _client/_socket at the end, which left the previous socket live and
    // unreferenced — still connected to the same DC, still being fed by the
    // server, under a *different* auth key. The login screen makes that easy
    // to hit: every Send Code tap calls connect(), so two failed attempts
    // left three sockets racing each other.
    await _socket?.close();
    _client = null;
    _socket = null;

    _dcId = dcId ?? _dcId;

    final fake = debugConnectOverride;
    if (fake != null) {
      await fake(_dcId, authKey);
      if (epoch != _sessionEpoch) {
        await _socket?.close();
        _client = null;
        _socket = null;
        _lastKey = null;
        throw StateError(_clearedWhileConnecting);
      }
      final attached = this.client;
      _lastKey = attached.authorizationKey;
      return attached;
    }

    final dc = _resolveDc(_dcId);

    // ignore: avoid_print
    print('TVDIAG: connect() socket.connect to ${dc.ip}:${dc.port}...');
    final rawSocket = await Socket.connect(dc.ip, dc.port,
        timeout: const Duration(seconds: 20));
    // ignore: avoid_print
    print('TVDIAG: connect() socket connected');
    final ioSocket = IoSocket(rawSocket);
    final obfuscation = tg.Obfuscation.random(false, _dcId);
    final idGenerator = tg.MessageIdGenerator();

    await ioSocket.send(obfuscation.preamble);
    // ignore: avoid_print
    print('TVDIAG: connect() preamble sent, authKey=${authKey != null}');

    final key = authKey ??
        await tg.Client.authorize(ioSocket, obfuscation, idGenerator)
            .timeout(const Duration(seconds: 20));
    // ignore: avoid_print
    print('TVDIAG: connect() have key, building client + initConnection...');

    final client = tg.Client(
      socket: ioSocket,
      obfuscation: obfuscation,
      authorizationKey: key,
      idGenerator: idGenerator,
    );

    // The headless WorkManager engine (see headless_sync.dart) and the upload
    // isolate never go through AuthNotifier, which is the only other place
    // this gets initialized — without this, apiId! below threw a null-check
    // there and background backup silently did nothing.
    await ApiCredentialsService.instance.init();
    final cfg = await client.initConnection<t.Config>(
      apiId: ApiCredentialsService.instance.apiId!,
      deviceModel: 'TeleVault',
      systemVersion: Platform.operatingSystem,
      appVersion: '1.0.0',
      systemLangCode: 'en',
      langPack: '',
      langCode: 'en',
      query: const t.HelpGetConfig(),
    ).timeout(const Duration(seconds: 20));
    // ignore: avoid_print
    print('TVDIAG: connect() initConnection done');

    // Capture the authoritative DC list so migrations land on the right server.
    final config = cfg.result;
    if (config is t.Config) {
      _dcOptions = config.dcOptions.whereType<t.DcOption>().toList();
    }

    // clearSession ran while this connection was being made (a reconnect
    // started by a revocation probe, for one): installing it would put the
    // forgotten key back in memory.
    if (epoch != _sessionEpoch) {
      await ioSocket.close();
      throw StateError(_clearedWhileConnecting);
    }

    _socket = ioSocket;
    _client = client;
    _lastKey = key;
    return client;
  }

  static const _clearedWhileConnecting = 'Session was cleared while connecting';

  /// Bumped by [clearSession]. [connect] captures it at the start and drops
  /// its new connection if it changed before the connection was installed.
  int _sessionEpoch = 0;

  /// Closes the current connection without touching the saved session, so the
  /// next [connect] starts clean. Used after a transport failure during login,
  /// where the connection can be left half-open in a way [isUsable] can't see.
  Future<void> dropConnection() async {
    await _socket?.close();
    _client = null;
    _socket = null;
  }

  Future<void> reconnectToDc(int dcId) async {
    await _socket?.close();
    _client = null;
    _socket = null;
    await connect(dcId: dcId);
  }

  /// How long a reconnect attempt gets before [call] gives up on it. [connect]
  /// already bounds each of its own steps (socket connect, auth, initConnection)
  /// to 20s individually, so a healthy reconnect always finishes well inside
  /// this — it exists only to catch whatever *isn't* individually bounded in
  /// there (e.g. a stalled OS-level connect that doesn't honor its own
  /// timeout under certain network conditions).
  static const _reconnectTimeout = Duration(seconds: 30);

  /// Executes [action] against the live client, reconnecting once on any
  /// transport failure (SocketDeadException, TimeoutException, SocketException).
  /// Use this instead of accessing [client] directly in all services so that
  /// MIUI's aggressive socket-killing is handled transparently.
  ///
  /// Every reconnect() call here is wrapped in [_reconnectTimeout] —
  /// including the very first one, before any RPC is even attempted. That one
  /// used to run unbounded: if it ever hung (Dart has no way to cancel a
  /// stuck Future, so nothing downstream can preempt it), every caller
  /// sharing this client — including ThumbnailService's fixed-size pool —
  /// stayed blocked on it forever, with no path back to a working state short
  /// of restarting the app. Now a stuck reconnect surfaces as a real
  /// exception instead, which every caller already knows how to handle
  /// (ThumbnailService's callers, for one, already catch and fall back to a
  /// placeholder — they just never got the chance to before).
  ///
  /// Two liveness guards on top of the RPC inactivity timeout (30 s without
  /// receiving anything, see [rpcInactivityTimeout]; a silently dropped
  /// connection used to cost a full 30s per request):
  ///  - the action races [IoSocket.done], so a socket that dies mid-request
  ///    fails the request immediately with [SocketDeadException];
  ///  - if nothing has been received for [_idleProbeAfter], a cheap RPC probes
  ///    the connection first and a failed probe reconnects before the real
  ///    action. (`help.getNearestDc` rather than `ping`: the vendored tg does
  ///    not handle Pong, so a ping would never complete.)
  ///
  /// RPC errors come back as a `t.Result` carrying the error, not thrown. A
  /// `FLOOD_WAIT_N` error is handled here, once, for every caller: with
  /// N <= [maxFloodWaitSeconds] the same [action] is retried after N+1 s, at
  /// most [maxFloodWaitRetries] times; a longer wait (or one still there after
  /// the retries) throws [FloodWaitException] instead of returning the error.
  ///
  /// The wait is shared: a FLOOD_WAIT closes a per-isolate gate
  /// ([_noteFloodWait]) and every call, a new one or a retry, first waits for
  /// it ([_awaitFloodGate]). One flood pauses all the callers once, instead of
  /// each of them running into its own flood while the others keep asking.
  Future<T> call<T>(Future<T> Function(tg.Client) action) async {
    for (var retry = 0;; retry++) {
      await _awaitFloodGate();
      final value = await _callOnce(action);
      _noteAuthError(value);
      final seconds = _floodWaitOf(value);
      if (seconds == null) return value;
      if (seconds > maxFloodWaitSeconds) {
        // ignore: avoid_print
        print('TVDIAG: FLOOD_WAIT ${seconds}s, giving up (retries $retry)');
        throw FloodWaitException(seconds);
      }
      _noteFloodWait(seconds);
      if (retry >= maxFloodWaitRetries) {
        // ignore: avoid_print
        print('TVDIAG: FLOOD_WAIT ${seconds}s, giving up (retries $retry)');
        throw FloodWaitException(seconds);
      }
    }
  }

  /// When the shared flood gate opens again (null: never closed). Only a
  /// FLOOD_WAIT up to [maxFloodWaitSeconds] closes it: a longer one fails its
  /// caller fast and must not freeze every other request for minutes.
  DateTime? _floodGateUntil;

  /// Called once each time the gate closes (not when an open gate is only
  /// extended), with the wait Telegram asked for. Returns the concurrency of
  /// the bulk thumbnail fetch after it reacted (for the log line), or null.
  /// Set by the thumbnail fetch (`server_thumb_batch.dart`) in its isolate.
  int? Function(int seconds)? onFloodGate;

  static final math.Random _jitterRandom = math.Random();

  /// Test-only: replaces the clock the gate reads.
  @visibleForTesting
  DateTime Function()? debugClock;

  /// Test-only: replaces the random jitter added to a gate.
  @visibleForTesting
  Duration Function()? debugFloodJitter;

  /// Test-only: opens the gate and drops the flood hook.
  @visibleForTesting
  void debugResetFloodGate() {
    _floodGateUntil = null;
    onFloodGate = null;
  }

  /// The gate's closing time (tests).
  @visibleForTesting
  DateTime? get floodGateUntil => _floodGateUntil;

  DateTime _now() => (debugClock ?? DateTime.now)();

  /// Closes the gate for N+1 s (plus up to half a second of jitter, so callers
  /// released together do not hit Telegram in the same instant). Overlapping
  /// waits keep the later opening time. The first flood of an episode, the one
  /// that finds the gate open, logs one line and tells [onFloodGate]; floods of
  /// calls that were already in flight when it closed only extend it.
  void _noteFloodWait(int seconds) {
    final now = _now();
    final jitter = debugFloodJitter?.call() ??
        Duration(milliseconds: _jitterRandom.nextInt(500));
    final until = now.add(Duration(seconds: seconds + 1)).add(jitter);
    final current = _floodGateUntil;
    final wasClosed = current != null && now.isBefore(current);
    if (!wasClosed || until.isAfter(current)) _floodGateUntil = until;
    if (wasClosed) return;
    final concurrency = onFloodGate?.call(seconds);
    // ignore: avoid_print
    print('TVDIAG: flood gate ${seconds}s (concurrency=${concurrency ?? '-'})');
  }

  /// Waits until the gate is open. A gate extended while waiting is waited
  /// out again; otherwise the one wait is enough.
  Future<void> _awaitFloodGate() async {
    while (true) {
      final until = _floodGateUntil;
      if (until == null) return;
      final wait = until.difference(_now());
      if (wait <= Duration.zero) return;
      await (debugFloodWaitDelay ?? _floodWaitDelay)(wait);
      if (_floodGateUntil == until) return;
    }
  }

  /// Set by the app: runs the local cleanup + login routing once a revocation
  /// is confirmed (see [confirmRevocation]). Null in the worker isolates and
  /// the headless engine, which have no UI to route: there an auth error just
  /// fails the request (the UI isolate learns of it through its own calls and
  /// the transfer queue's failures).
  Future<void> Function()? onSessionRevoked;

  /// After an inconclusive or transient probe, further auth errors do not
  /// probe again for this long (a mass upload failing 100 times must not
  /// cost 100 probes and reconnects).
  @visibleForTesting
  Duration revocationCooldown = const Duration(seconds: 15);

  Future<bool>? _revocationCheck;
  DateTime? _revocationCheckedAt;

  /// Test-only: replaces the probe RPC. Returns the error message the
  /// request came back with, or null when it succeeded.
  @visibleForTesting
  Future<String?> Function(tg.Client client)? debugRevocationProbe;

  /// A revocation hint seen in an RPC result: starts [confirmRevocation].
  void _noteAuthError(Object? value) {
    if (onSessionRevoked == null) return;
    if (value is! t.Result) return;
    final message = value.error?.errorMessage;
    if (message == null || !isRevocationError(message)) return;
    unawaited(confirmRevocation().catchError((Object _) => false));
  }

  /// Confirms with one probe (`users.getUsers` for self, on a fresh
  /// connection that reuses the session key) that the server really dropped
  /// this session, and then runs [onSessionRevoked]. Returns true only for a
  /// confirmed revocation.
  ///
  /// Anything short of that — the probe succeeding (a transient error), failing
  /// for another reason (offline, timeout, flood), the connection not being
  /// the home DC's, or the session having changed meanwhile — returns false and
  /// leaves the session alone: wiping a good session forces a full re-login
  /// (phone + code + 2FA). Concurrent callers share one check.
  Future<bool> confirmRevocation() {
    final inFlight = _revocationCheck;
    if (inFlight != null) return inFlight;
    final last = _revocationCheckedAt;
    if (last != null && DateTime.now().difference(last) < revocationCooldown) {
      return Future.value(false);
    }
    final check = _confirmRevocation();
    _revocationCheck = check;
    check.whenComplete(() {
      if (identical(_revocationCheck, check)) _revocationCheck = null;
    }).ignore();
    return check;
  }

  Future<bool> _confirmRevocation() async {
    final home = _homeDcId;
    final key = _lastKey;
    if (home == null || key == null || _dcId != home) {
      debugPrint('TVAUTH: auth error outside the home session, not a revocation');
      return false;
    }
    var confirmed = false;
    try {
      // A fresh socket on the same key (I1: never a new handshake): rules
      // out a connection that merely went bad.
      await reconnect().timeout(_reconnectTimeout);
      final message = await _probeSelf(client);
      confirmed = message != null && isRevocationError(message);
      debugPrint('TVAUTH: revocation probe '
          '${confirmed ? 'confirmed' : message == null ? 'ok (transient)' : 'inconclusive'}');
    } catch (e) {
      debugPrint('TVAUTH: revocation probe failed (${e.runtimeType}), keeping session');
    }
    _revocationCheckedAt = DateTime.now();
    if (!confirmed) return false;
    // The user may have logged out (or in as someone else) while probing.
    if (_homeDcId != home || _lastKey?.id != key.id) return false;
    final handler = onSessionRevoked;
    if (handler == null) return false;
    try {
      await handler();
    } catch (e) {
      debugPrint('TVAUTH: revocation handler failed (${e.runtimeType})');
    }
    return true;
  }

  /// The probe RPC: the error message it came back with, null on success.
  Future<String?> _probeSelf(tg.Client c) async {
    final fake = debugRevocationProbe;
    if (fake != null) return fake(c);
    final result = await _attempt(
      c,
      _socket,
      (c) => c.users.getUsers(id: const [t.InputUserSelf()]),
    );
    return result.error?.errorMessage;
  }

  /// Test-only: marks the authenticated session's home DC.
  @visibleForTesting
  void debugSetHomeDc(int? dcId) => _homeDcId = dcId;

  /// Longest FLOOD_WAIT that [call] waits out instead of failing fast.
  static const int maxFloodWaitSeconds = 120;

  /// How many times [call] retries one action after a FLOOD_WAIT.
  static const int maxFloodWaitRetries = 3;

  /// Test-only: replaces the real wait of a FLOOD_WAIT retry.
  @visibleForTesting
  Future<void> Function(Duration wait)? debugFloodWaitDelay;

  /// The FLOOD_WAIT seconds carried by [value], if it is such an RPC error.
  static int? _floodWaitOf(Object? value) {
    if (value is! t.Result) return null;
    final error = value.error;
    if (error == null) return null;
    return floodWaitSecondsOf(error.errorMessage);
  }

  /// Waits [wait] in short steps, reporting progress in between: run on the
  /// download worker (the index `remote*` functions), the caller's
  /// inactivity timeout would otherwise read a long wait as a stalled call.
  static Future<void> _floodWaitDelay(Duration wait) async {
    const step = Duration(seconds: 10);
    var left = wait;
    while (left > Duration.zero) {
      final d = left < step ? left : step;
      await Future<void>.delayed(d);
      left -= d;
      WorkerProgress.report(0);
    }
  }

  Future<T> _callOnce<T>(Future<T> Function(tg.Client) action) async {
    if (_socket?.isDead == true || _client == null) {
      await reconnect().timeout(_reconnectTimeout);
    }
    var used = client;
    await _probeIfIdle(used);
    // The probe may have replaced the connection.
    used = client;
    try {
      return await _attempt(used, _socket, action);
    } on TimeoutException {
      await _reconnectUnlessReplaced(used);
      return await _attempt(client, _socket, action);
    } on SocketDeadException {
      await _reconnectUnlessReplaced(used);
      return await _attempt(client, _socket, action);
    } on SocketException {
      await _reconnectUnlessReplaced(used);
      return await _attempt(client, _socket, action);
    }
  }

  /// An RPC fails with [TimeoutException] once nothing has been received on
  /// its socket for this long while it is pending. Inactivity, not total
  /// time: a 1 MiB getFile window (4 in flight per document, more with
  /// concurrent downloads) can legitimately take well over 30 s on a slow
  /// link while bytes keep arriving.
  @visibleForTesting
  Duration rpcInactivityTimeout = const Duration(seconds: 30);

  /// Absolute cap per RPC, whatever the socket activity (safety net for a
  /// request whose answer never comes on an otherwise busy connection).
  @visibleForTesting
  Duration rpcMaxDuration = const Duration(minutes: 5);

  /// Watchdog timers currently armed by [_withInactivityTimeout]
  /// (diagnostics / tests: must return to 0 once every RPC settles).
  int _activeRpcWatchdogs = 0;

  @visibleForTesting
  int get activeRpcWatchdogs => _activeRpcWatchdogs;

  /// Runs [action] with the RPC inactivity timeout, failing immediately with
  /// [SocketDeadException] if [socket] is (or becomes) dead.
  Future<T> _attempt<T>(
    tg.Client c,
    IoSocket? socket,
    Future<T> Function(tg.Client) action,
  ) {
    if (socket == null) return action(c).timeout(rpcInactivityTimeout);
    final result = _withInactivityTimeout<T>(action(c), socket);
    return _raceSocketDead<T>(result, socket);
  }

  /// Fails [result] with [TimeoutException] when [socket] has received
  /// nothing for [rpcInactivityTimeout] since the call started (or since its
  /// last receive), or after [rpcMaxDuration] in total. One timer at a time,
  /// cancelled as soon as [result] settles, so nothing outlives the RPC.
  Future<T> _withInactivityTimeout<T>(Future<T> result, IoSocket socket) {
    final inactivity = rpcInactivityTimeout;
    final maxDuration = rpcMaxDuration;
    final started = DateTime.now();
    final completer = Completer<T>();
    Timer? timer;
    var armed = true;
    _activeRpcWatchdogs++;

    void disarm() {
      if (!armed) return;
      armed = false;
      timer?.cancel();
      timer = null;
      _activeRpcWatchdogs--;
    }

    void check() {
      timer = null;
      if (!armed) return;
      final now = DateTime.now();
      final last =
          socket.lastReceive.isAfter(started) ? socket.lastReceive : started;
      final idle = now.difference(last);
      final total = now.difference(started);
      if (idle >= inactivity || total >= maxDuration) {
        disarm();
        if (!completer.isCompleted) {
          completer.completeError(TimeoutException(
            idle >= inactivity
                ? 'RPC: nothing received for ${inactivity.inSeconds}s'
                : 'RPC: exceeded ${maxDuration.inSeconds}s',
            idle >= inactivity ? inactivity : maxDuration,
          ));
        }
        return;
      }
      final untilIdle = inactivity - idle;
      final untilCap = maxDuration - total;
      timer = Timer(untilIdle < untilCap ? untilIdle : untilCap, check);
    }

    timer = Timer(inactivity < maxDuration ? inactivity : maxDuration, check);
    result.then<void>((value) {
      disarm();
      if (!completer.isCompleted) completer.complete(value);
    }, onError: (Object e, StackTrace st) {
      disarm();
      if (!completer.isCompleted) completer.completeError(e, st);
    });
    return completer.future;
  }

  /// Races [result] against [socket] dying. Not `Future.any([result,
  /// socket.done...])`: that leaves a listener on the long-lived `done` future
  /// per RPC, which keeps every RPC result reachable for the life of the
  /// connection (a 1 GB download = ~1000 retained 1 MB chunks). The on-dead
  /// callback is removed as soon as the action settles.
  Future<T> _raceSocketDead<T>(Future<T> result, IoSocket socket) {
    final completer = Completer<T>();
    void onDead() {
      if (!completer.isCompleted) {
        completer.completeError(const SocketDeadException());
      }
    }

    socket.addOnDead(onDead);
    result.then<void>((value) {
      socket.removeOnDead(onDead);
      if (!completer.isCompleted) completer.complete(value);
    }, onError: (Object e, StackTrace st) {
      socket.removeOnDead(onDead);
      if (!completer.isCompleted) completer.completeError(e, st);
    });
    return completer.future;
  }

  /// Idle time after which [call] probes the connection before using it.
  @visibleForTesting
  Duration idleProbeAfter = const Duration(seconds: 20);

  /// How long the probe RPC gets before the connection is declared dead.
  @visibleForTesting
  Duration probeTimeout = const Duration(seconds: 5);

  /// Reconnects triggered by a failed idle probe (diagnostics / tests).
  int probeReconnects = 0;

  /// In-flight probe, shared by concurrent callers so N requests on an idle
  /// connection cause one probe and at most one reconnect.
  Future<void>? _probing;

  Future<void> _probeIfIdle(tg.Client used) async {
    final socket = _socket;
    if (socket == null || !identical(_client, used)) return;
    if (DateTime.now().difference(socket.lastReceive) <= idleProbeAfter) return;
    var probe = _probing;
    if (probe == null) {
      probe = _runProbe(used, socket);
      _probing = probe;
      final started = probe;
      started.whenComplete(() {
        if (identical(_probing, started)) _probing = null;
      }).ignore();
    }
    await probe;
  }

  Future<void> _runProbe(tg.Client used, IoSocket socket) async {
    try {
      await _attemptProbe(used, socket);
    } catch (_) {
      probeReconnects++;
      // ignore: avoid_print
      print('TVDIAG: idle probe failed, reconnecting (#$probeReconnects)');
      await _reconnectUnlessReplaced(used);
    }
  }

  Future<void> _attemptProbe(tg.Client used, IoSocket socket) {
    return _raceSocketDead<void>(
      used.ping().timeout(probeTimeout),
      socket,
    );
  }

  /// Test-only: installs an already-built connection so [call] can be driven
  /// without touching the network.
  @visibleForTesting
  void debugAttach(tg.Client client, IoSocket socket, {int dcId = 2}) {
    _client = client;
    _socket = socket;
    _dcId = dcId;
    _lastKey = client.authorizationKey;
  }

  /// Test-only: replaces the real reconnect (which dials Telegram). The
  /// override is expected to call [debugAttach] with the fresh connection.
  @visibleForTesting
  Future<void> Function()? debugReconnectOverride;

  /// Test-only: replaces the network part of [connect] (socket, handshake,
  /// initConnection). Receives the DC and the key [connect] was asked to use;
  /// throws to simulate a failed connect, or calls [debugAttach] on success.
  @visibleForTesting
  Future<void> Function(int dcId, tg.AuthorizationKey? authKey)?
      debugConnectOverride;

  /// Test-only: forgets the in-memory key (what [clearSession] does, without
  /// touching the session file).
  @visibleForTesting
  void debugForgetKey() => _lastKey = null;

  /// With several requests in flight (parallel upload parts / download
  /// windows), one that times out late must not tear down a connection another
  /// request already replaced — that killed the retries running on the fresh
  /// socket. Only reconnect if [used] is still the live client.
  Future<void> _reconnectUnlessReplaced(tg.Client used) async {
    final inFlight = _reconnecting;
    if (inFlight != null) {
      await inFlight.timeout(_reconnectTimeout);
      return;
    }
    if (!identical(_client, used) && _client != null && _socket?.isDead != true) return;
    await reconnect().timeout(_reconnectTimeout);
  }

  /// Test-only: simulates MIUI killing the live socket. The next [call] must
  /// detect the dead socket and reconnect transparently.
  @visibleForTesting
  void debugKillSocket() => _socket?.debugKill();

  /// In-flight reconnect, shared by every concurrent caller — see [reconnect].
  Future<void>? _reconnecting;

  /// Reconnects to the current DC reusing the existing authorization key.
  /// Call this when a timeout indicates the socket died (e.g. MIUI killed it).
  ///
  /// Backgrounding the app (MIUI cuts network) can make many in-flight
  /// requests fail at once, and [call] invokes this per-request — without
  /// the guard below, two concurrent callers could interleave: the first
  /// reads the current key and nulls out [_client], then the SECOND reads
  /// [_client]`?.authorizationKey` and gets null (the first caller already
  /// cleared it), so it reconnects with authKey: null — a fresh MTProto
  /// handshake that the server never associated with this Telegram account,
  /// silently swapping in an unusable key. Every subsequent request then
  /// fails with AUTH_KEY_UNREGISTERED, and reconnecting again doesn't help
  /// because the corruption already happened. Sharing one in-flight
  /// reconnect future means concurrent callers all wait for and reuse the
  /// same successful reconnect instead of racing to start their own.
  Future<void> reconnect() {
    final inFlight = _reconnecting;
    if (inFlight != null) return inFlight;
    final future = _doReconnect();
    _reconnecting = future;
    // .ignore(): the derived future would otherwise surface a failed
    // reconnect as an unhandled error; callers get it through `future`.
    future.whenComplete(() {
      if (identical(_reconnecting, future)) _reconnecting = null;
    }).ignore();
    return future;
  }

  Future<void> _doReconnect() async {
    final override = debugReconnectOverride;
    if (override != null) {
      await _socket?.close();
      _client = null;
      _socket = null;
      await override();
      return;
    }
    // _client is null after a failed reconnect or a dropConnection(); the key
    // must survive that, or the connect below would negotiate a brand-new,
    // unregistered key (see [_lastKey]).
    final epoch = _sessionEpoch;
    final key = _client?.authorizationKey ?? _lastKey;
    await _socket?.close();
    _client = null;
    _socket = null;
    // clearSession may have run during the close above; do not put its key back.
    if (epoch != _sessionEpoch) throw StateError(_clearedWhileConnecting);
    if (key == null) {
      // A handshake only ever happens through an explicit connect() (login).
      throw StateError(
          'No authorization key to reconnect with: sign in (or restore the '
          'session) first.');
    }
    _lastKey = key;
    await connect(dcId: _dcId, authKey: key);
  }

  /// Restores a saved session, reconnecting to its DC with its key. Returns
  /// false if there is nothing saved.
  Future<bool> restoreSession() async {
    // ignore: avoid_print
    print('TVDIAG: restoreSession() loading session file...');
    final saved = await _loadSession();
    // ignore: avoid_print
    print('TVDIAG: restoreSession() session loaded: ${saved != null}');
    if (saved == null) return false;
    await connect(dcId: saved.dcId, authKey: saved.key);
    _homeDcId = saved.dcId;
    return true;
  }

  Future<void> saveSession() async {
    final c = _client;
    if (c == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final data = jsonEncode({
      'dcId': _dcId,
      'key': c.authorizationKey.toJson(),
    });
    await File('${dir.path}/tele_vault_session.json').writeAsString(data);
    _homeDcId = _dcId;
  }

  /// Forgets the session: the in-memory key, the home DC, the connection and
  /// the session file. After this no [call] can reach Telegram (reconnecting
  /// needs a key, and a handshake only ever happens through [connect]).
  Future<void> clearSession() async {
    _sessionEpoch++;
    _lastKey = null;
    _homeDcId = null;
    _revocationCheckedAt = null;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/tele_vault_session.json');
    if (await file.exists()) await file.delete();
    await _socket?.close();
    _client = null;
    _socket = null;
  }

  Future<bool> hasSession() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/tele_vault_session.json').exists();
  }

  Future<_Session?> _loadSession() async {
    try {
      // ignore: avoid_print
      print('TVDIAG: _loadSession() calling getApplicationDocumentsDirectory()...');
      final dir = await getApplicationDocumentsDirectory();
      // ignore: avoid_print
      print('TVDIAG: _loadSession() got dir');
      final file = File('${dir.path}/tele_vault_session.json');
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final key = tg.AuthorizationKey.fromJson(json['key'] as Map<String, dynamic>);
      return _Session(json['dcId'] as int? ?? 2, key);
    } catch (_) {
      return null;
    }
  }
}
