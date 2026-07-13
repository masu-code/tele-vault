import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;
import '../config.dart';
import 'io_socket.dart';

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

  /// DC list reported by the server. Preferred over [_seedDcs] when present,
  /// since seed IPs can drift and only cover the common datacenters.
  List<t.DcOption> _dcOptions = [];

  tg.Client get client {
    final c = _client;
    if (c == null) throw StateError('Not connected. Call connect() first.');
    return c;
  }

  bool get isConnected => _client != null;

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
    _dcId = dcId ?? _dcId;
    final dc = _resolveDc(_dcId);

    final rawSocket = await Socket.connect(dc.ip, dc.port,
        timeout: const Duration(seconds: 20));
    final ioSocket = IoSocket(rawSocket);
    final obfuscation = tg.Obfuscation.random(false, _dcId);
    final idGenerator = tg.MessageIdGenerator();

    await ioSocket.send(obfuscation.preamble);

    final key = authKey ??
        await tg.Client.authorize(ioSocket, obfuscation, idGenerator)
            .timeout(const Duration(seconds: 20));

    final client = tg.Client(
      socket: ioSocket,
      obfuscation: obfuscation,
      authorizationKey: key,
      idGenerator: idGenerator,
    );

    final cfg = await client.initConnection<t.Config>(
      apiId: Config.apiId,
      deviceModel: 'TeleVault',
      systemVersion: Platform.operatingSystem,
      appVersion: '1.0.0',
      systemLangCode: 'en',
      langPack: '',
      langCode: 'en',
      query: const t.HelpGetConfig(),
    ).timeout(const Duration(seconds: 20));

    // Capture the authoritative DC list so migrations land on the right server.
    final config = cfg.result;
    if (config is t.Config) {
      _dcOptions = config.dcOptions.whereType<t.DcOption>().toList();
    }

    _socket = ioSocket;
    _client = client;
    return client;
  }

  Future<void> reconnectToDc(int dcId) async {
    await _socket?.close();
    _client = null;
    _socket = null;
    await connect(dcId: dcId);
  }

  /// Executes [action] against the live client, reconnecting once on any
  /// transport failure (SocketDeadException, TimeoutException, SocketException).
  /// Use this instead of accessing [client] directly in all services so that
  /// MIUI's aggressive socket-killing is handled transparently.
  Future<T> call<T>(Future<T> Function(tg.Client) action) async {
    if (_socket?.isDead == true || _client == null) await reconnect();
    try {
      return await action(client).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      await reconnect();
      return await action(client).timeout(const Duration(seconds: 30));
    } on SocketDeadException {
      await reconnect();
      return await action(client).timeout(const Duration(seconds: 30));
    } on SocketException {
      await reconnect();
      return await action(client).timeout(const Duration(seconds: 30));
    }
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
    future.whenComplete(() {
      if (identical(_reconnecting, future)) _reconnecting = null;
    });
    return future;
  }

  Future<void> _doReconnect() async {
    final key = _client?.authorizationKey;
    await _socket?.close();
    _client = null;
    _socket = null;
    await connect(dcId: _dcId, authKey: key);
  }

  /// Restores a saved session, reconnecting to its DC with its key. Returns
  /// false if there is nothing saved.
  Future<bool> restoreSession() async {
    final saved = await _loadSession();
    if (saved == null) return false;
    await connect(dcId: saved.dcId, authKey: saved.key);
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
  }

  Future<void> clearSession() async {
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
      final dir = await getApplicationDocumentsDirectory();
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
