import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:t/t.dart' as t;
import 'package:tele_vault/app/app.dart';
import 'package:tele_vault/core/telegram/client.dart';
import 'package:tele_vault/core/telegram/io_socket.dart';
import 'package:tele_vault/features/auth/providers/auth_provider.dart';
import 'package:tele_vault/features/auth/screens/phone_screen.dart';
import 'package:tele_vault/features/auth/session_cleanup.dart';
import 'package:tg/tg.dart' as tg;

/// A session killed by the server (logged out from another device) while the
/// app is open. [TelegramService.call] sees AUTH_KEY_UNREGISTERED /
/// SESSION_REVOKED, confirms with one probe on a fresh connection that reuses
/// the key, and only then runs the local cleanup and routes to login. A
/// transient error, an inconclusive probe, or an error on a DC that is not the
/// session's home DC must leave the session alone.

t.Result<t.Pong> _authError([String m = 'AUTH_KEY_UNREGISTERED']) =>
    t.Result<t.Pong>.error(t.RpcError(errorCode: 401, errorMessage: m));

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

Future<void> _until(bool Function() ok, {String? reason}) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out: ${reason ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServerSocket server;
  final serverSides = <Socket>[];
  final ios = <IoSocket>[];
  final sessionKey = tg.AuthorizationKey(901, Uint8List(256), 5);
  late TelegramService svc;
  var revoked = 0;
  var probes = 0;
  final requestedKeys = <tg.AuthorizationKey?>[];

  Future<(tg.Client, IoSocket)> connectionWith(tg.AuthorizationKey key) async {
    final raw = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final io = IoSocket(raw);
    io.receiver.listen((_) {}, onError: (_) {});
    io.lastReceive = DateTime.now();
    ios.add(io);
    final client = tg.Client(
      socket: io,
      obfuscation: tg.Obfuscation.random(false, 2),
      authorizationKey: key,
      idGenerator: tg.MessageIdGenerator(),
    );
    return (client, io);
  }

  /// Attaches a live connection on [dcId]; [home] is the authenticated
  /// session's DC (null = logging in, nothing authorized yet).
  Future<void> attach({int dcId = 2, int? home = 2}) async {
    final (c, io) = await connectionWith(sessionKey);
    svc.debugAttach(c, io, dcId: dcId);
    svc.debugSetHomeDc(home);
  }

  setUp(() async {
    svc = TelegramService.instance;
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      serverSides.add(s);
      s.listen((_) {}, onError: (_) {});
    });
    revoked = 0;
    probes = 0;
    requestedKeys.clear();
    svc.idleProbeAfter = const Duration(hours: 1);
    svc.revocationCooldown = Duration.zero;
    svc.onSessionRevoked = () async => revoked++;
    // The probe's reconnect: a fresh connection on whatever key it is handed.
    svc.debugConnectOverride = (dcId, authKey) async {
      requestedKeys.add(authKey);
      final (c, io) = await connectionWith(authKey!);
      svc.debugAttach(c, io, dcId: dcId);
    };
  });

  tearDown(() async {
    svc.onSessionRevoked = null;
    svc.debugRevocationProbe = null;
    svc.debugConnectOverride = null;
    svc.debugReconnectOverride = null;
    svc.debugSetHomeDc(null);
    svc.revocationCooldown = const Duration(seconds: 15);
    svc.idleProbeAfter = const Duration(seconds: 20);
    await svc.dropConnection();
    svc.debugForgetKey();
    for (final io in ios) {
      try {
        await io.close();
      } catch (_) {}
    }
    ios.clear();
    for (final s in serverSides) {
      s.destroy();
    }
    serverSides.clear();
    await server.close();
  });

  group('TelegramService revocation detection', () {
    test('AUTH_KEY_UNREGISTERED confirmed by the probe: handler runs once, key reused',
        () async {
      await attach();
      svc.debugRevocationProbe = (_) async {
        probes++;
        return 'AUTH_KEY_UNREGISTERED';
      };

      final r = await svc.call<t.Result<t.Pong>>((_) async => _authError());
      // The caller still gets the raw result: detection never swallows it.
      expect(r.error?.errorMessage, 'AUTH_KEY_UNREGISTERED');

      await _until(() => revoked == 1, reason: 'handler called');
      expect(probes, 1);
      // I1: the probe's reconnect reused the session key, no new handshake.
      expect(requestedKeys, hasLength(1));
      expect(requestedKeys.single!.id, sessionKey.id);
    });

    test('SESSION_REVOKED counts as well', () async {
      await attach();
      svc.debugRevocationProbe = (_) async => 'SESSION_REVOKED';
      await svc.call<t.Result<t.Pong>>((_) async => _authError('SESSION_REVOKED'));
      await _until(() => revoked == 1);
    });

    test('a transient 401 followed by a successful probe does NOT log out', () async {
      await attach();
      svc.debugRevocationProbe = (_) async {
        probes++;
        return null; // getUsers answered: the key is fine
      };

      await svc.call<t.Result<t.Pong>>((_) async => _authError());
      await _until(() => probes == 1, reason: 'probe ran');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(revoked, 0);
      expect(svc.isConnected, isTrue);
      // The session is intact and still usable.
      final key = await svc.call<tg.AuthorizationKey>((c) => Future.value(c.authorizationKey));
      expect(key.id, sessionKey.id);
    });

    test('an inconclusive probe (offline, flood, other error) does NOT log out', () async {
      await attach();
      var n = 0;
      svc.debugRevocationProbe = (_) async {
        probes++;
        if (n++ == 0) throw const SocketException('offline');
        return 'FLOOD_WAIT_9';
      };

      await svc.call<t.Result<t.Pong>>((_) async => _authError());
      await _until(() => probes == 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await svc.call<t.Result<t.Pong>>((_) async => _authError());
      await _until(() => probes == 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(revoked, 0);
    });

    test('AUTH_KEY_UNREGISTERED on a non-home DC does NOT log out (and is not probed)',
        () async {
      // The session lives on DC 2; this connection is on DC 4 (a file-DC
      // migration / exported authorization is expected to fail like this
      // until it is authorized there).
      await attach(dcId: 4, home: 2);
      svc.debugRevocationProbe = (_) async {
        probes++;
        return 'AUTH_KEY_UNREGISTERED';
      };

      await svc.call<t.Result<t.Pong>>((_) async => _authError());
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(probes, 0);
      expect(revoked, 0);
      expect(requestedKeys, isEmpty, reason: 'no reconnect either');
    });

    test('during login (no authenticated session yet) an auth error is not a revocation',
        () async {
      await attach(home: null);
      svc.debugRevocationProbe = (_) async {
        probes++;
        return 'AUTH_KEY_UNREGISTERED';
      };

      await svc.call<t.Result<t.Pong>>((_) async => _authError());
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(probes, 0);
      expect(revoked, 0);
    });

    test('other RPC errors never start a probe', () async {
      await attach();
      svc.debugRevocationProbe = (_) async {
        probes++;
        return 'AUTH_KEY_UNREGISTERED';
      };

      await svc.call<t.Result<t.Pong>>((_) async => _authError('PHONE_CODE_INVALID'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(probes, 0);
      expect(revoked, 0);
    });

    test('many failing calls share one probe', () async {
      await attach();
      final gate = Completer<void>();
      svc.debugRevocationProbe = (_) async {
        probes++;
        await gate.future;
        return 'AUTH_KEY_UNREGISTERED';
      };

      await Future.wait([
        for (var i = 0; i < 5; i++) svc.call<t.Result<t.Pong>>((_) async => _authError()),
      ]);
      await _until(() => probes == 1);
      gate.complete();
      await _until(() => revoked == 1);
      expect(probes, 1);
    });

    test('a user logging out while the probe runs wins: no second cleanup', () async {
      await attach();
      final gate = Completer<void>();
      svc.debugRevocationProbe = (_) async {
        await gate.future;
        return 'AUTH_KEY_UNREGISTERED';
      };
      await svc.call<t.Result<t.Pong>>((_) async => _authError());
      svc.debugSetHomeDc(null); // what clearSession does
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(revoked, 0);
    });
  });

  group('clearSession', () {
    late Directory docs;
    late PathProviderPlatform previousPaths;

    setUp(() {
      docs = Directory.systemTemp.createTempSync('tv_session_test_');
      previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePaths(docs.path);
    });

    tearDown(() {
      PathProviderPlatform.instance = previousPaths;
      try {
        docs.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('forgets the key and the session file: no call can reach Telegram afterwards',
        () async {
      await attach();
      final file = File('${docs.path}/tele_vault_session.json')..writeAsStringSync('{}');
      expect(await svc.hasSession(), isTrue);

      await svc.clearSession();

      expect(file.existsSync(), isFalse);
      expect(await svc.hasSession(), isFalse);
      expect(svc.isConnected, isFalse);
      // _lastKey is gone: a reconnect throws instead of handshaking (I1).
      await expectLater(
        svc.reconnect(),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('No authorization key'))),
      );
      await expectLater(svc.call<int>((c) => Future.value(1)), throwsA(isA<StateError>()));
      expect(requestedKeys, isEmpty, reason: 'no handshake, no connect');
    });

    test('a reconnect in flight when the session is cleared does not bring the key back',
        () async {
      await attach();
      final gate = Completer<void>();
      svc.debugConnectOverride = (dcId, authKey) async {
        requestedKeys.add(authKey);
        await gate.future;
        final (c, io) = await connectionWith(authKey!);
        svc.debugAttach(c, io, dcId: dcId);
      };
      final reconnect = svc.reconnect();
      final outcome = reconnect.then<Object?>((_) => null, onError: (Object e) => e);
      await _until(() => requestedKeys.isNotEmpty, reason: 'connect started');

      await svc.clearSession();
      gate.complete();

      expect(await outcome, isA<StateError>());
      expect(svc.isConnected, isFalse);
      // The key did not come back: a new reconnect cannot handshake with it.
      await expectLater(
        svc.reconnect(),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('No authorization key'))),
      );
      expect(requestedKeys, hasLength(1), reason: 'no second connect');
    });

    test('telegramServerLogOut never throws, even with nothing to log out of', () async {
      await svc.clearSession();
      await telegramServerLogOut(timeout: const Duration(seconds: 2));
    });
  });

  group('routing to login', () {
    testWidgets('a confirmed revocation pops every route and shows the message',
        (tester) async {
      final steps = <String>[];
      final cleanup = _recordingCleanup(steps);
      final auth = AuthNotifier.withoutRestore(
        const AuthState(step: AuthStep.authenticated, restoring: false),
        cleanup: cleanup,
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [authProvider.overrideWith((ref) => auth)],
        child: const TeleVaultApp(debugSignedInHome: Scaffold(body: Text('home'))),
      ));
      expect(find.text('home'), findsOneWidget);

      // A screen pushed over the home (the account sheet, a viewer...).
      Navigator.of(tester.element(find.text('home')))
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('pushed'))));
      await tester.pumpAndSettle();
      expect(find.text('pushed'), findsOneWidget);

      await tester.runAsync(() async {
        await attach();
        svc.debugRevocationProbe = (_) async => 'AUTH_KEY_UNREGISTERED';
        await svc.call<t.Result<t.Pong>>((_) async => _authError());
        await _until(() => steps.contains('reset app state'), reason: 'cleanup ran');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(steps, [
        'stop transfers',
        'cancel background tasks',
        // no 'server log out': the server already ended it
        'clear session',
        'reset workers',
        'clear index',
        'reset app state',
      ]);
      expect(find.byType(PhoneScreen), findsOneWidget);
      expect(find.text(sessionRevokedMessage), findsOneWidget);
      expect(find.text('pushed'), findsNothing);
      expect(find.text('home'), findsNothing);
      expect(auth.state.restoring, isFalse, reason: 'not the cold-start splash');
      expect(auth.state.isAuthenticated, isFalse);
    });

    testWidgets('a transient 401 leaves the user where they are', (tester) async {
      final steps = <String>[];
      final auth = AuthNotifier.withoutRestore(
        const AuthState(step: AuthStep.authenticated, restoring: false),
        cleanup: _recordingCleanup(steps),
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [authProvider.overrideWith((ref) => auth)],
        child: const TeleVaultApp(debugSignedInHome: Scaffold(body: Text('home'))),
      ));

      await tester.runAsync(() async {
        await attach();
        svc.debugRevocationProbe = (_) async {
          probes++;
          return null;
        };
        await svc.call<t.Result<t.Pong>>((_) async => _authError());
        await _until(() => probes == 1);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      expect(steps, isEmpty);
      expect(find.text('home'), findsOneWidget);
      expect(find.byType(PhoneScreen), findsNothing);
      expect(auth.state.isAuthenticated, isTrue);
    });

    testWidgets('a revocation while not signed in is ignored', (tester) async {
      final steps = <String>[];
      final auth = AuthNotifier.withoutRestore(
        const AuthState(restoring: false),
        cleanup: _recordingCleanup(steps),
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [authProvider.overrideWith((ref) => auth)],
        child: const TeleVaultApp(debugSignedInHome: Scaffold(body: Text('home'))),
      ));

      await tester.runAsync(() async {
        await attach();
        svc.debugRevocationProbe = (_) async => 'AUTH_KEY_UNREGISTERED';
        await svc.call<t.Result<t.Pong>>((_) async => _authError());
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();

      expect(steps, isEmpty);
      expect(find.text(sessionRevokedMessage), findsNothing);
    });
  });
}

SessionCleanup _recordingCleanup(List<String> steps, {List<int>? bound}) {
  Future<void> step(String name) async => steps.add(name);
  return SessionCleanup(
    stopTransfers: () => step('stop transfers'),
    cancelBackgroundTasks: () => step('cancel background tasks'),
    serverLogOut: () => step('server log out'),
    clearSession: () => step('clear session'),
    resetWorkers: () => step('reset workers'),
    clearIndex: () => step('clear index'),
    resetAppState: () => step('reset app state'),
    bindAccount: (id) async => bound?.add(id),
    resumeBackgroundTasks: () => step('resume background tasks'),
  );
}
