import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;
import '../config.dart';
import 'io_socket.dart';

// Known Telegram production DCs
const _dcs = [
  (id: 1, ip: '149.154.167.50', port: 443),
  (id: 2, ip: '149.154.167.40', port: 443),
  (id: 3, ip: '149.154.175.100', port: 443),
  (id: 4, ip: '149.154.167.91', port: 443),
  (id: 5, ip: '91.108.56.180', port: 443),
];

class TelegramService {
  TelegramService._();
  static final TelegramService instance = TelegramService._();

  tg.Client? _client;
  IoSocket? _socket;
  int _dcId = 2;

  tg.Client get client {
    final c = _client;
    if (c == null) throw StateError('Not connected. Call connect() first.');
    return c;
  }

  bool get isConnected => _client != null;

  Future<tg.Client> connect({int? dcId}) async {
    _dcId = dcId ?? _dcId;
    final dc = _dcs.firstWhere((d) => d.id == _dcId);

    final rawSocket = await Socket.connect(dc.ip, dc.port);
    final ioSocket = IoSocket(rawSocket);
    final obfuscation = tg.Obfuscation.random(false, _dcId);
    final idGenerator = tg.MessageIdGenerator();

    await ioSocket.send(obfuscation.preamble);

    final savedKey = await _loadKey();
    final authKey = savedKey ??
        await tg.Client.authorize(ioSocket, obfuscation, idGenerator);

    final client = tg.Client(
      socket: ioSocket,
      obfuscation: obfuscation,
      authorizationKey: authKey,
      idGenerator: idGenerator,
    );

    await client.initConnection<t.Config>(
      apiId: Config.apiId,
      deviceModel: 'TeleVault',
      systemVersion: Platform.operatingSystem,
      appVersion: '1.0.0',
      systemLangCode: 'en',
      langPack: '',
      langCode: 'en',
      query: const t.HelpGetConfig(),
    );

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

  Future<void> saveSession() async {
    final c = _client;
    if (c == null) return;
    final dir = await getApplicationDocumentsDirectory();
    await File('${dir.path}/tele_vault_session.json')
        .writeAsString(c.authorizationKey.toString());
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

  Future<tg.AuthorizationKey?> _loadKey() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/tele_vault_session.json');
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      return tg.AuthorizationKey.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
