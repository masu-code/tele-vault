// Generates test/goldens/tg_0_0_20_goldens.json from the ORIGINAL (unmodified)
// tg 0.0.20 transport code, reached through `TgInternals` / the public
// `Obfuscation` / `AesCtr` classes.
//
// RUN ONCE. The fixture is the frozen oracle that every later optimization of
// the transport is compared against. Never regenerate it: the generator refuses
// to overwrite an existing file, and the sha256 of the first output is recorded
// in packages/tg/VENDORED.md (checked by the test).
//
//   dart run tool/gen_goldens.dart
//
// This file also holds the helpers shared with the tests/bench (deterministic
// input generator, message builder, canonical JSON, receiver harness).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart';

/// Master seed of the fixture (every random choice comes from `Random(seed)`).
const int goldenMasterSeed = 20261109;

// ---------------------------------------------------------------------------
// Shared helpers (used by the tests and the bench too)
// ---------------------------------------------------------------------------

/// Deterministic byte generator (xorshift64*), independent of `dart:math`
/// internals, used for every input that is not stored verbatim in the fixture.
Uint8List detBytes(int seed, int len) {
  final out = Uint8List(len);
  var x = seed ^ 0x2545F4914F6CDD1D;
  if (x == 0) x = 1;
  for (var i = 0; i < len; i++) {
    x ^= x >>> 12;
    x ^= x << 25;
    x ^= x >>> 27;
    out[i] = ((x * 0x2545F4914F6CDD1D) >>> 56) & 0xFF;
  }
  return out;
}

String hex(List<int> b) {
  final sb = StringBuffer();
  for (final v in b) {
    sb.write(v.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List unhex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String sha256Hex(List<int> b) => c.sha256.convert(b).toString();

/// Builds a TL object from its fixture spec.
t.TlObject buildMessage(Map<String, dynamic> s) {
  switch (s['t'] as String) {
    case 'UploadSaveFilePart':
      return t.UploadSaveFilePart(
        fileId: s['fileId'] as int,
        filePart: s['filePart'] as int,
        bytes: detBytes(s['bytesSeed'] as int, s['bytesLen'] as int),
      );
    case 'MsgsAck':
      return t.MsgsAck(msgIds: List<int>.from(s['ids'] as List));
    case 'HelpGetConfig':
      return const t.HelpGetConfig();
    case 'Pong':
      return t.Pong(msgId: s['msgId'] as int, pingId: s['pingId'] as int);
    case 'UploadFileResult':
      return t.RpcResult(
        reqMsgId: s['reqMsgId'] as int,
        result: t.UploadFile(
          type: const t.StorageFileJpeg(),
          mtime: s['mtime'] as int,
          bytes: detBytes(s['bytesSeed'] as int, s['bytesLen'] as int),
        ),
      );
    case 'NewSessionCreated':
      return t.NewSessionCreated(
        firstMsgId: s['firstMsgId'] as int,
        uniqueId: s['uniqueId'] as int,
        serverSalt: s['serverSalt'] as int,
      );
    case 'BadServerSalt':
      return t.BadServerSalt(
        badMsgId: s['badMsgId'] as int,
        badMsgSeqno: s['badMsgSeqno'] as int,
        errorCode: s['errorCode'] as int,
        newServerSalt: s['newServerSalt'] as int,
      );
  }
  throw ArgumentError('unknown message spec ${s['t']}');
}

Uint8List serializeObject(t.TlObject m) {
  final b = <int>[];
  m.serialize(b);
  return Uint8List.fromList(b);
}

/// Canonical, comparable form of a decoded TL object: `toJson()` with byte
/// arrays replaced by `bytes:<len>:<sha256>`.
Object? canon(Object? v) {
  if (v is Uint8List) return 'bytes:${v.length}:${sha256Hex(v)}';
  if (v is t.TlObject) return canon(v.toJson());
  if (v is Map) {
    return {for (final e in v.entries) '${e.key}': canon(e.value)};
  }
  if (v is List) return v.map(canon).toList();
  if (v == null || v is num || v is String || v is bool) return v;
  return v.toString();
}

/// Splits [wire] into chunks following a chunking spec
/// (`{kind: fixed, size: n}` or `{kind: list, sizes: [...]}`).
List<Uint8List> applyChunking(Uint8List wire, Map<String, dynamic> spec) {
  final chunks = <Uint8List>[];
  var pos = 0;
  if (spec['kind'] == 'fixed') {
    final size = spec['size'] as int;
    while (pos < wire.length) {
      final end = min(pos + size, wire.length);
      chunks.add(Uint8List.sublistView(wire, pos, end));
      pos = end;
    }
  } else {
    for (final s in List<int>.from(spec['sizes'] as List)) {
      if (pos >= wire.length) break;
      final end = min(pos + s, wire.length);
      chunks.add(Uint8List.sublistView(wire, pos, end));
      pos = end;
    }
    if (pos < wire.length) {
      chunks.add(Uint8List.sublistView(wire, pos, wire.length));
    }
  }
  return chunks;
}

/// Feeds [chunks] to a receive pipeline built by [attach] and collects every
/// decoded object.
Future<List<t.TlObject>> collectReceived(
  Stream<t.TlObject> Function(Stream<List<int>> raw) attach,
  List<Uint8List> chunks,
) async {
  final done = Completer<void>();
  final raw = Stream<List<int>>.fromIterable(chunks).transform(
    StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleDone: (sink) {
        sink.close();
        done.complete();
      },
    ),
  );
  final out = <t.TlObject>[];
  attach(raw).listen(out.add);
  await done.future;
  // Broadcast delivery is scheduled through microtasks; let them drain.
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  return out;
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

Uint8List _rb(Random r, int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

int _r62(Random r) => (r.nextInt(1 << 30) << 32) | r.nextInt(1 << 32);

Map<String, dynamic> _newAuth(Random r) => {
      'id': _r62(r) | 1,
      'key': hex(_rb(r, 256)),
      'salt': _r62(r),
    };

AuthorizationKey _authFrom(Map<String, dynamic> a) =>
    AuthorizationKey(a['id'] as int, unhex(a['key'] as String), a['salt'] as int);

Future<void> main(List<String> args) async {
  final force = args.contains('--force');
  final outUri = Platform.script.resolve('../test/goldens/tg_0_0_20_goldens.json');
  final outFile = File.fromUri(outUri);
  if (outFile.existsSync() && !force) {
    stderr.writeln('REFUSING to overwrite ${outFile.path}: the golden fixture '
        'must be generated once from the original code and never regenerated.');
    exitCode = 2;
    return;
  }

  final r = Random(goldenMasterSeed);
  final g = <String, dynamic>{
    'meta': {
      'fixture': 'tg_0_0_20_goldens',
      'tg_version': '0.0.20',
      'master_seed': goldenMasterSeed,
      'bytes_generator': 'xorshift64* (detBytes in tool/gen_goldens.dart)',
      'note': 'Generated from the unmodified tg code via TgInternals. '
          'Never regenerate.',
    },
  };

  // ---- AES-IGE ------------------------------------------------------------
  final igeLens = <int>[16, 32, 48, 64, 128, 256, 1024, 4096];
  while (igeLens.length < 40) {
    igeLens.add((1 + r.nextInt(256)) * 16);
  }
  final ige = <Map<String, dynamic>>[];
  for (var i = 0; i < igeLens.length; i++) {
    final encrypt = i.isEven;
    final key = _rb(r, 32);
    final iv = _rb(r, 32);
    final input = _rb(r, igeLens[i]);
    final out = TgInternals.aesIge(input, key, iv, encrypt: encrypt);
    // Sanity: the inverse direction restores the input.
    final back = TgInternals.aesIge(out, key, iv, encrypt: !encrypt);
    if (hex(back) != hex(input)) throw StateError('IGE roundtrip failed $i');
    ige.add({
      'encrypt': encrypt,
      'key': hex(key),
      'iv': hex(iv),
      'input': hex(input),
      'output': hex(out),
    });
  }
  g['ige'] = ige;

  final igeBig = <Map<String, dynamic>>[];
  var seed = 1000;
  for (final len in [65536, 1048576]) {
    for (final encrypt in [true, false]) {
      final key = _rb(r, 32);
      final iv = _rb(r, 32);
      final input = detBytes(++seed, len);
      final out = TgInternals.aesIge(input, key, iv, encrypt: encrypt);
      igeBig.add({
        'encrypt': encrypt,
        'key': hex(key),
        'iv': hex(iv),
        'inputSeed': seed,
        'len': len,
        'outputSha256': sha256Hex(out),
      });
    }
  }
  g['igeBig'] = igeBig;

  // ---- message crypt (x in {0, 8}) ---------------------------------------
  final authKeys = [_newAuth(r), _newAuth(r)];
  final msgcrypt = <Map<String, dynamic>>[];
  for (var i = 0; i < 16; i++) {
    final x = (i & 1) == 0 ? 0 : 8;
    final encrypt = (i & 2) == 0;
    final offset = (i & 4) == 0 ? 0 : 8;
    final ak = authKeys[(i >> 3) & 1];
    final msgKey = _rb(r, 24);
    final input = _rb(r, (1 + r.nextInt(32)) * 16);
    final out = TgInternals.encryptDecryptMessage(
      input,
      encrypt: encrypt,
      x: x,
      authKey: unhex(ak['key'] as String),
      msgKey: msgKey,
      msgKeyOffset: offset,
    );
    msgcrypt.add({
      'encrypt': encrypt,
      'x': x,
      'authKey': ak['key'],
      'msgKey': hex(msgKey),
      'msgKeyOffset': offset,
      'input': hex(input),
      'output': hex(out),
    });
  }
  {
    final msgKey = _rb(r, 16);
    final input = detBytes(77, 65536);
    final out = TgInternals.encryptDecryptMessage(
      input,
      encrypt: true,
      x: 0,
      authKey: unhex(authKeys[0]['key'] as String),
      msgKey: msgKey,
      msgKeyOffset: 0,
    );
    msgcrypt.add({
      'encrypt': true,
      'x': 0,
      'authKey': authKeys[0]['key'],
      'msgKey': hex(msgKey),
      'msgKeyOffset': 0,
      'inputSeed': 77,
      'len': 65536,
      'outputSha256': sha256Hex(out),
    });
  }
  g['msgcrypt'] = msgcrypt;

  // ---- encodeWithAuth / encodeNoAuth --------------------------------------
  final specs = <Map<String, dynamic>>[
    for (final n in [0, 1, 253, 254, 255, 4096, 524288])
      {
        't': 'UploadSaveFilePart',
        'fileId': _r62(r),
        'filePart': r.nextInt(1000),
        'bytesLen': n,
        'bytesSeed': 5000 + n,
      },
    {
      't': 'MsgsAck',
      'ids': [_r62(r), _r62(r), _r62(r)],
    },
    {'t': 'HelpGetConfig'},
  ];
  final withAuth = <Map<String, dynamic>>[];
  final noAuth = <Map<String, dynamic>>[];
  for (var i = 0; i < specs.length; i++) {
    final spec = specs[i];
    final m = buildMessage(spec);
    final msgLen = serializeObject(m).length;
    final pad =
        ((0x7FFFFFF0 - (msgLen + 32)) % 16) + (2 + r.nextInt(14)) * 16;
    final padding = _rb(r, pad);
    final ak = authKeys[i & 1];
    final msgId = _r62(r) & ~3;
    final seqno = r.nextInt(1000);
    final sessionId = _r62(r);
    final out = TgInternals.encodeWithAuth(
      m,
      msgId: msgId,
      seqno: seqno,
      sessionId: sessionId,
      auth: _authFrom(ak),
      padding: padding,
    );
    withAuth.add({
      'spec': spec,
      'auth': ak,
      'msgId': msgId,
      'seqno': seqno,
      'sessionId': sessionId,
      'padding': hex(padding),
      'outputLen': out.length,
      'outputSha256': sha256Hex(out),
      if (out.length <= 1500) 'output': hex(out),
    });

    final nid = _r62(r) & ~3;
    final nout = TgInternals.encodeNoAuth(m, msgId: nid);
    noAuth.add({
      'spec': spec,
      'msgId': nid,
      'outputLen': nout.length,
      'outputSha256': sha256Hex(nout),
      if (nout.length <= 1500) 'output': hex(nout),
    });
  }
  g['encodeWithAuth'] = withAuth;
  g['encodeNoAuth'] = noAuth;

  // ---- CTR streams ---------------------------------------------------------
  final ctr = <Map<String, dynamic>>[];
  final ivs = <Map<String, dynamic>>[
    {'kind': 'random', 'iv': hex(_rb(r, 16))},
    {'kind': 'allFF', 'iv': 'ff' * 16},
    {'kind': 'lowFF', 'iv': '0011223344556677${'ff' * 8}'},
  ];
  final patterns = <int>[1, 3, 4, 15, 16, 17, 1000, 4096];
  var ctrSeed = 9000;
  for (final ivSpec in ivs) {
    final key = _rb(r, 32);
    for (var p = 0; p <= patterns.length; p++) {
      // p < patterns.length: constant chunk size; p == length: the mixed list.
      final mixed = p == patterns.length;
      final chunks = mixed ? patterns : [patterns[p]];
      final total = mixed ? patterns.fold<int>(0, (a, b) => a + b) : 8192;
      final input = detBytes(++ctrSeed, total);
      final ctrObj = AesCtr(key, unhex(ivSpec['iv'] as String));
      final out = Uint8List(total);
      var pos = 0;
      var ci = 0;
      while (pos < total) {
        final size = min(chunks[ci % chunks.length], total - pos);
        ci++;
        final chunk = Uint8List.fromList(input.sublist(pos, pos + size));
        ctrObj.encryptDecrypt(chunk, chunk.length);
        out.setRange(pos, pos + size, chunk);
        pos += size;
      }
      ctr.add({
        'key': hex(key),
        'iv': ivSpec['iv'],
        'ivKind': ivSpec['kind'],
        'chunks': chunks,
        'cycle': !mixed,
        'total': total,
        'inputSeed': ctrSeed,
        'outputSha256': sha256Hex(out),
        if (mixed && ivSpec['kind'] == 'random') 'output': hex(out),
      });
    }
  }
  g['ctr'] = ctr;

  // ---- Obfuscation preamble + send/recv streams --------------------------
  final obfCases = <Map<String, dynamic>>[];
  for (var i = 0; i < 6; i++) {
    final random58 = _rb(r, 58);
    final padded = i.isEven;
    final dcId = [2, 4, 5, 10002, 3, 1][i];
    final secret = i == 5 ? _rb(r, 16) : null;
    final o = Obfuscation.preamble(random58, padded, dcId, secret);
    final input = detBytes(300 + i, 64);
    final sendOut = <String>[];
    final recvOut = <String>[];
    for (var k = 0; k < 3; k++) {
      final a = Uint8List.fromList(input);
      o.send.encryptDecrypt(a, 64);
      sendOut.add(hex(a));
      final b = Uint8List.fromList(input);
      o.recv.encryptDecrypt(b, 64);
      recvOut.add(hex(b));
    }
    obfCases.add({
      'random58': hex(random58),
      'padded': padded,
      'dcId': dcId,
      if (secret != null) 'secret': hex(secret),
      'preamble': hex(o.preamble),
      'inputSeed': 300 + i,
      'sendOut': sendOut,
      'recvOut': recvOut,
    });
  }
  g['obfuscation'] = obfCases;

  // ---- server -> client encrypted frames -----------------------------------
  final srvAuth = _newAuth(r);
  final srvAuthKey = unhex(srvAuth['key'] as String);
  final srvAuthId = srvAuth['id'] as int;
  final obfRandom = _rb(r, 58);
  final frameSpecs = <Map<String, dynamic>>[
    {'t': 'Pong', 'msgId': _r62(r), 'pingId': _r62(r)},
    {
      't': 'UploadFileResult',
      'reqMsgId': _r62(r),
      'mtime': 1700000000,
      'bytesLen': 4096,
      'bytesSeed': 7001,
    },
    {
      't': 'NewSessionCreated',
      'firstMsgId': _r62(r),
      'uniqueId': _r62(r),
      'serverSalt': _r62(r),
    },
    {
      't': 'BadServerSalt',
      'badMsgId': _r62(r),
      'badMsgSeqno': 7,
      'errorCode': 48,
      'newServerSalt': _r62(r),
    },
    {
      't': 'MsgsAck',
      'ids': [_r62(r), _r62(r)],
    },
    {
      't': 'UploadFileResult',
      'reqMsgId': _r62(r),
      'mtime': 1700000123,
      'bytesLen': 16384,
      'bytesSeed': 7002,
    },
    {'t': 'Pong', 'msgId': _r62(r), 'pingId': _r62(r)},
    {
      't': 'UploadFileResult',
      'reqMsgId': _r62(r),
      'mtime': 1700000456,
      'bytesLen': 253,
      'bytesSeed': 7003,
    },
  ];
  final seqnos = <int>[1, 3, 5, 7, 8, 9, 11, 13];
  final srvObf = Obfuscation.preamble(obfRandom, false, 2);
  final wireParts = <Uint8List>[];
  final msgs = <Map<String, dynamic>>[];
  final expectedAcks = <int>[];
  for (var i = 0; i < frameSpecs.length; i++) {
    final m = buildMessage(frameSpecs[i]);
    final body = serializeObject(m);
    final salt = _r62(r);
    final session = _r62(r);
    final msgId = (_r62(r) & ~3) | 1;
    final seqno = seqnos[i];

    final head = BytesBuilder()
      ..add(_le(salt, 8))
      ..add(_le(session, 8))
      ..add(_le(msgId, 8))
      ..add(_le(seqno, 4))
      ..add(_le(body.length, 4))
      ..add(body);
    var p = 12 + r.nextInt(32);
    p += (16 - ((32 + body.length + p) % 16)) % 16;
    head.add(_rb(r, p));
    final plain = head.toBytes();
    if (plain.length % 16 != 0) throw StateError('bad padding');

    final msgKey = Uint8List.fromList(c.sha256
        .convert([...srvAuthKey.sublist(96, 128), ...plain])
        .bytes
        .sublist(8, 24));
    final cipher = TgInternals.encryptDecryptMessage(
      plain,
      encrypt: true,
      x: 8,
      authKey: srvAuthKey,
      msgKey: msgKey,
      msgKeyOffset: 0,
    );
    final frameBody = BytesBuilder()
      ..add(_le(srvAuthId, 8))
      ..add(msgKey)
      ..add(cipher);
    final bodyBytes = frameBody.toBytes();
    final wire = BytesBuilder()
      ..add(_le(bodyBytes.length, 4))
      ..add(bodyBytes);
    final wireBytes = wire.toBytes();
    srvObf.recv.encryptDecrypt(wireBytes, wireBytes.length); // server -> client
    wireParts.add(wireBytes);

    if ((seqno & 1) != 0) expectedAcks.add(msgId);
    msgs.add({
      'spec': frameSpecs[i],
      'msgId': msgId,
      'seqno': seqno,
      'salt': salt,
      'session': session,
      'bodyHex': hex(bodyBytes),
      'expectedJson': canon(m),
    });
  }
  final wireAll = Uint8List.fromList([for (final w in wireParts) ...w]);
  final sizes = <int>[];
  {
    var left = wireAll.length;
    while (left > 0) {
      final s = 1 + r.nextInt(300);
      sizes.add(s);
      left -= s;
    }
  }
  final chunkings = <Map<String, dynamic>>[
    {'kind': 'list', 'sizes': sizes},
    {'kind': 'fixed', 'size': 1},
    {'kind': 'fixed', 'size': 4},
    {'kind': 'fixed', 'size': wireAll.length},
  ];

  // Sanity: run the ORIGINAL receiver over every chunking and compare with the
  // expected decoded objects, so a generator bug cannot slip into the fixture.
  for (final chunking in chunkings) {
    final acks = <int>{};
    final got = await collectReceived(
      (raw) => TgInternals.encryptedReceiver(
        raw,
        Obfuscation.preamble(obfRandom, false, 2),
        AuthorizationKey(srvAuthId, srvAuthKey, srvAuth['salt'] as int),
        acks,
      ),
      applyChunking(wireAll, chunking),
    );
    if (got.length != msgs.length) {
      throw StateError('receiver returned ${got.length}/${msgs.length}');
    }
    for (var i = 0; i < got.length; i++) {
      if (jsonEncode(canon(got[i])) != jsonEncode(msgs[i]['expectedJson'])) {
        throw StateError('receiver mismatch at $i');
      }
    }
    if (!(acks.length == expectedAcks.length && acks.containsAll(expectedAcks))) {
      throw StateError('ack set mismatch');
    }
  }

  // Obfuscated single-frame parse (frame body obfuscated from stream offset 0).
  final firstBody = unhex(msgs[0]['bodyHex'] as String);
  final obfBody = Uint8List.fromList(firstBody);
  Obfuscation.preamble(obfRandom, false, 2).recv.encryptDecrypt(obfBody, obfBody.length);

  g['frames'] = {
    'authKey': srvAuth,
    'obf': {'random58': hex(obfRandom), 'padded': false, 'dcId': 2},
    'messages': msgs,
    'wire': hex(wireAll),
    'chunkings': chunkings,
    'expectedAcks': (List<int>.from(expectedAcks)..sort()),
    'parseObfuscated': {
      'dataHex': hex(obfBody),
      'index': 0,
    },
  };

  // ---- unencrypted frames ---------------------------------------------------
  final plainSpecs = <Map<String, dynamic>>[
    {'t': 'Pong', 'msgId': _r62(r), 'pingId': _r62(r)},
    {
      't': 'NewSessionCreated',
      'firstMsgId': _r62(r),
      'uniqueId': _r62(r),
      'serverSalt': _r62(r),
    },
    {
      't': 'UploadFileResult',
      'reqMsgId': _r62(r),
      'mtime': 1700000789,
      'bytesLen': 1000,
      'bytesSeed': 7101,
    },
  ];
  final plainObfRandom = _rb(r, 58);
  final plainSrvObf = Obfuscation.preamble(plainObfRandom, true, 4);
  final plainFrames = <Map<String, dynamic>>[];
  final plainWirePlain = BytesBuilder();
  final plainWireObf = BytesBuilder();
  for (final s in plainSpecs) {
    final m = buildMessage(s);
    final msgId = _r62(r) & ~3;
    final bytesPlain = TgInternals.frameToBytes(m, msgId, null);
    final bytesObf = TgInternals.frameToBytes(
      m,
      msgId,
      Obfuscation.preamble(plainObfRandom, true, 4), // fresh send keystream
    );
    // Same bytes as the dedicated no-auth encoder.
    if (hex(bytesPlain) != hex(TgInternals.encodeNoAuth(m, msgId: msgId))) {
      throw StateError('frameToBytes != encodeNoAuth');
    }
    plainWirePlain.add(bytesPlain);
    final forWire = Uint8List.fromList(bytesPlain);
    plainSrvObf.recv.encryptDecrypt(forWire, forWire.length);
    plainWireObf.add(forWire);
    plainFrames.add({
      'spec': s,
      'msgId': msgId,
      'frameToBytesPlain': hex(bytesPlain),
      'frameToBytesObfFresh': hex(bytesObf),
      'expectedJson': canon(m),
    });
  }
  g['unencrypted'] = {
    'obf': {'random58': hex(plainObfRandom), 'padded': true, 'dcId': 4},
    'frames': plainFrames,
    'wirePlain': hex(plainWirePlain.toBytes()),
    'wireObfuscated': hex(plainWireObf.toBytes()),
    'chunkings': [
      {'kind': 'list', 'sizes': [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233]},
      {'kind': 'fixed', 'size': 1},
      {'kind': 'fixed', 'size': 100000},
    ],
  };

  // ---- write ----------------------------------------------------------------
  outFile.parent.createSync(recursive: true);
  final bytes = utf8.encode(jsonEncode(g));
  outFile.writeAsBytesSync(bytes);
  stdout.writeln('wrote ${outFile.path}');
  stdout.writeln('size: ${bytes.length} bytes');
  stdout.writeln('sha256: ${sha256Hex(bytes)}');
}

Uint8List _le(int v, int n) {
  final b = Uint8List(n);
  final bd = ByteData.sublistView(b);
  if (n == 8) {
    bd.setUint64(0, v, Endian.little);
  } else {
    bd.setUint32(0, v, Endian.little);
  }
  return b;
}
