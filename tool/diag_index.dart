// Temporary read-only diagnostic: lists every TeleVault index snapshot in
// Saved Messages and reports size + file counts. Delete after use.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;
import 'package:tele_vault/core/telegram/io_socket.dart';

const marker = 'TELEVAULT_INDEX_V1';

/// The Telegram api id, from the environment (`TV_API_ID`), so the tool does
/// not depend on the gitignored `lib/core/config.dart`. Only the id is needed:
/// this tool reuses an existing session and never signs in, so no api hash.
int _apiIdFromEnv() {
  final raw = Platform.environment['TV_API_ID'];
  final id = raw == null ? null : int.tryParse(raw.trim());
  if (id == null || id <= 0) {
    stderr.writeln('diag_index: set TV_API_ID to your Telegram api id '
        '(an integer from my.telegram.org) before running this tool.');
    exit(64);
  }
  return id;
}

Future<void> main(List<String> args) async {
  final apiId = _apiIdFromEnv();
  final sessionPath = args.isNotEmpty
      ? args[0]
      : '${Platform.environment['USERPROFILE']}/.tele_vault_device_session.json';
  final json = jsonDecode(await File(sessionPath).readAsString()) as Map<String, dynamic>;
  final dcId = json['dcId'] as int;
  final key = tg.AuthorizationKey.fromJson(json['key'] as Map<String, dynamic>);

  const seeds = {
    1: '149.154.175.53',
    2: '149.154.167.51',
    3: '149.154.175.100',
    4: '149.154.167.91',
    5: '91.108.56.130',
  };
  final raw = await Socket.connect(seeds[dcId]!, 443, timeout: const Duration(seconds: 20));
  final io = IoSocket(raw);
  final obf = tg.Obfuscation.random(false, dcId);
  final ids = tg.MessageIdGenerator();
  await io.send(obf.preamble);
  final client = tg.Client(
    socket: io,
    obfuscation: obf,
    authorizationKey: key,
    idGenerator: ids,
  );
  await client.initConnection<t.Config>(
    apiId: apiId,
    deviceModel: 'TeleVault',
    systemVersion: 'diag',
    appVersion: '1.0.0',
    systemLangCode: 'en',
    langPack: '',
    langCode: 'en',
    query: const t.HelpGetConfig(),
  ).timeout(const Duration(seconds: 20));

  final res = await client.messages.search(
    peer: const t.InputPeerSelf(),
    q: marker,
    filter: const t.InputMessagesFilterDocument(),
    minDate: DateTime.fromMillisecondsSinceEpoch(0),
    maxDate: DateTime.fromMillisecondsSinceEpoch(0),
    offsetId: 0,
    addOffset: 0,
    limit: 100,
    maxId: 0,
    minId: 0,
    hash: 0,
  );
  if (res.error != null) {
    print('SEARCH ERROR: ${res.error!.errorMessage}');
    exit(1);
  }
  final r = res.result;
  final List<t.MessageBase> msgs = switch (r) {
    t.MessagesMessages(:final messages) => messages,
    t.MessagesMessagesSlice(:final messages) => messages,
    t.MessagesChannelMessages(:final messages) => messages,
    _ => const [],
  };
  print('search returned ${msgs.length} messages');
  for (final m in msgs) {
    if (m is! t.Message) continue;
    if (!m.message.startsWith(marker)) continue;
    final media = m.media;
    var info = 'text';
    var files = -1;
    if (media is t.MessageMediaDocument && media.document is t.Document) {
      final doc = media.document as t.Document;
      info = 'doc ${doc.size} bytes';
      final loc = t.InputDocumentFileLocation(
        id: doc.id,
        accessHash: doc.accessHash,
        fileReference: doc.fileReference,
        thumbSize: '',
      );
      final b = BytesBuilder();
      var off = 0;
      while (off < doc.size) {
        final f = await client.upload.getFile(
          precise: false,
          cdnSupported: false,
          location: loc,
          offset: off,
          limit: 1024 * 1024,
        );
        if (f.error != null) {
          print('download error ${f.error!.errorMessage}');
          break;
        }
        final u = f.result as t.UploadFile;
        b.add(u.bytes);
        off += u.bytes.length;
        if (u.bytes.length < 1024 * 1024) break;
      }
      try {
        final map = jsonDecode(utf8.decode(b.toBytes())) as Map<String, dynamic>;
        final fl = (map['files'] as List?) ?? [];
        files = fl.length;
        final seen = <String, int>{};
        var dup = 0;
        for (final e in fl) {
          final k = '${e['name']}|${e['total_size']}';
          if (seen.containsKey(k)) dup++;
          seen[k] = 1;
        }
        info += ', folders=${(map['folders'] as List?)?.length}, albums=${(map['albums'] as List?)?.length}, dupNameSize=$dup';
      } catch (e) {
        info += ' (decode failed: $e)';
      }
    }
    print('id=${m.id} date=${m.date} $info files=$files');
  }
  exit(0);
}
