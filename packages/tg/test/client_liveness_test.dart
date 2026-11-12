// T1.3(j): Client robustness against a fake socket and a fake server that
// speaks real MTProto frames (obfuscated, encrypted, msg_key checked).
import 'dart:async';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:t/t.dart' as t;
import 'package:test/test.dart';
import 'package:tg/tg.dart';

import '../tool/gen_goldens.dart' show detBytes, serializeObject;

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

Uint8List _sha(List<int> a) => Uint8List.fromList(c.sha256.convert(a).bytes);

class FakeSocket extends SocketAbstraction {
  final ctrl = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];
  Object? failSends;

  @override
  Stream<Uint8List> get receiver => ctrl.stream;

  @override
  Future<void> send(List<int> data) async {
    final f = failSends;
    if (f != null) throw f;
    sent.add(Uint8List.fromList(data));
  }
}

class ClientMsg {
  ClientMsg(this.msgId, this.seqno, this.obj);
  final int msgId;
  final int seqno;
  final t.TlObject obj;
}

/// Server side of one connection: undoes the client's obfuscation, checks
/// and decrypts its frames, and pushes encrypted server frames.
class FakeServer {
  FakeServer(this.socket, Uint8List random58, this.authKey, this.authId)
      : _twin = Obfuscation.preamble(random58, false, 2);

  final FakeSocket socket;
  final Uint8List authKey;
  final int authId;
  final Obfuscation _twin;

  /// The client's session id; the client drops frames of any other session.
  int sessionId = 0x2222;
  int _consumed = 0;
  int _serverMsgId = (DateTime.now().millisecondsSinceEpoch ~/ 1000) << 32 | 1;

  int nextServerMsgId() => _serverMsgId += 4;

  /// Waits until [n] more client frames were sent and decodes them.
  Future<List<ClientMsg>> next(int n,
      {Duration timeout = const Duration(seconds: 2)}) async {
    final sw = Stopwatch()..start();
    while (socket.sent.length < _consumed + n) {
      if (sw.elapsed > timeout) {
        throw TimeoutException('expected $n client frames');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final out = <ClientMsg>[];
    while (_consumed < socket.sent.length) {
      out.add(_decode(socket.sent[_consumed++]));
    }
    return out;
  }

  ClientMsg _decode(Uint8List wire) {
    final f = Uint8List.fromList(wire);
    _twin.send.encryptDecrypt(f, f.length);
    final bd = ByteData.sublistView(f);
    expect(bd.getUint32(0, Endian.little), f.length - 4);
    expect(bd.getUint64(4, Endian.little), authId);
    final msgKey = Uint8List.fromList(f.sublist(12, 28));
    final plain = TgInternals.encryptDecryptMessage(
        Uint8List.fromList(f.sublist(28)),
        encrypt: false,
        x: 0,
        authKey: authKey,
        msgKey: msgKey,
        msgKeyOffset: 0);
    expect(_sha([...authKey.sublist(88, 120), ...plain]).sublist(8, 24), msgKey,
        reason: 'client msg_key');
    final pd = ByteData.sublistView(plain);
    final len = pd.getUint32(28, Endian.little);
    final obj = t.BinaryReader(Uint8List.fromList(plain.sublist(32, 32 + len)))
        .readObject();
    return ClientMsg(pd.getUint64(16, Endian.little),
        pd.getUint32(24, Endian.little), obj);
  }

  /// Pushes [m] (or raw TL [body]) as an encrypted server frame.
  void push({t.TlObject? m, Uint8List? body, int? msgId, int seqno = 0}) {
    final b = body ?? serializeObject(m!);
    final p = BytesBuilder()
      ..add(_le(0x1111, 8))
      ..add(_le(sessionId, 8))
      ..add(_le(msgId ?? nextServerMsgId(), 8))
      ..add(_le(seqno, 4))
      ..add(_le(b.length, 4))
      ..add(b);
    var pad = 16;
    pad += (16 - ((32 + b.length + pad) % 16)) % 16;
    p.add(detBytes(b.length, pad));
    final plain = p.toBytes();
    final msgKey = _sha([...authKey.sublist(96, 128), ...plain]).sublist(8, 24);
    final cipher = TgInternals.encryptDecryptMessage(plain,
        encrypt: true, x: 8, authKey: authKey, msgKey: msgKey, msgKeyOffset: 0);
    final frame = (BytesBuilder()
          ..add(_le(8 + 16 + cipher.length, 4))
          ..add(_le(authId, 8))
          ..add(msgKey)
          ..add(cipher))
        .toBytes();
    _twin.recv.encryptDecrypt(frame, frame.length);
    socket.ctrl.add(frame);
  }

  /// Injects [m] as a plaintext (auth_key_id 0) frame, as an on-path attacker
  /// that saw the obfuscation preamble could.
  void pushPlain(t.TlObject m, int msgId) {
    final frame = TgInternals.frameToBytes(m, msgId, null);
    _twin.recv.encryptDecrypt(frame, frame.length);
    socket.ctrl.add(frame);
  }
}

class Fixture {
  Fixture._(this.socket, this.client, this.server, this.idGenerator);

  factory Fixture() {
    final random58 = detBytes(4242, 58);
    final authKey = detBytes(4243, 256);
    const authId = 0x5566778899AABBCC;
    final socket = FakeSocket();
    final idGenerator = MessageIdGenerator();
    final client = Client(
      socket: socket,
      obfuscation: Obfuscation.preamble(random58, false, 2),
      authorizationKey: AuthorizationKey(authId, authKey, 0x1234),
      idGenerator: idGenerator,
    );
    return Fixture._(
        socket,
        client,
        FakeServer(socket, random58, authKey, authId)
          ..sessionId = client.sessionId,
        idGenerator);
  }

  final FakeSocket socket;
  final Client client;
  final FakeServer server;
  final MessageIdGenerator idGenerator;

  Future<void> close() async {
    if (!socket.ctrl.isClosed) await socket.ctrl.close();
  }
}

Uint8List _containerBytes(List<t.Msg> msgs) => Uint8List.fromList([
      ..._le(0x73f1f8dc, 4),
      ...serializeObject(t.MsgContainer(messages: msgs)),
    ]);

const _nearest = t.NearestDc(country: 'XX', thisDc: 2, nearestDc: 4);

void main() {
  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.close());

  test('Pong completes ping', () async {
    final ping = f.client.ping();
    final sent = await f.server.next(1);
    final p = sent.single.obj as t.Ping;
    f.server.push(m: t.Pong(msgId: sent.single.msgId, pingId: p.pingId));
    await ping.timeout(const Duration(seconds: 2));
  });

  test('Pong inside a container completes ping', () async {
    final ping = f.client.ping();
    final sent = await f.server.next(1);
    final p = sent.single.obj as t.Ping;
    f.server.push(
        body: _containerBytes([
      t.Msg(
          msgId: f.server.nextServerMsgId(),
          seqno: 0,
          bytes: 16,
          body: t.Pong(msgId: sent.single.msgId, pingId: p.pingId)),
    ]));
    await ping.timeout(const Duration(seconds: 2));
  });

  test('closing the socket fails pending calls at once, later calls too',
      () async {
    final call = f.client.help.getNearestDc();
    final call2 = f.client.ping();
    await f.server.next(2);
    final sw = Stopwatch()..start();
    await f.socket.ctrl.close();
    await expectLater(call, throwsA(isA<StateError>()));
    await expectLater(call2, throwsA(isA<StateError>()));
    expect(sw.elapsedMilliseconds, lessThan(100));
    await expectLater(f.client.help.getNearestDc(), throwsA(isA<StateError>()));
  });

  test('a receive error fails pending calls with that error', () async {
    final call = f.client.help.getNearestDc();
    await f.server.next(1);
    f.socket.ctrl.addError(const FormatException('boom'));
    await expectLater(call, throwsA(isA<FormatException>()));
  });

  test('failAllPending fails every pending call', () async {
    final a = f.client.help.getNearestDc();
    final b = f.client.help.getConfig();
    await f.server.next(2);
    f.client.failAllPending(const FormatException('x'));
    await expectLater(a, throwsA(isA<FormatException>()));
    await expectLater(b, throwsA(isA<FormatException>()));
  });

  test('a failed send surfaces the error and the call is not left pending',
      () async {
    f.socket.failSends = const FormatException('send');
    await expectLater(
        f.client.help.getNearestDc(), throwsA(isA<FormatException>()));
    f.socket.failSends = null;
    // Answering the dead msg id later must not complete anything (no crash).
    f.client.failAllPending(StateError('nothing pending'));
  });

  test('RpcResult with GzipPacked is decoded', () async {
    final call = f.client.help.getNearestDc();
    final sent = await f.server.next(1);
    f.server.push(
        m: t.RpcResult(
            reqMsgId: sent.single.msgId,
            result: t.GzipPacked(
                packedData: Uint8List.fromList(
                    gzip.encode(serializeObject(_nearest))))));
    final r = await call.timeout(const Duration(seconds: 2));
    expect((r.result as t.NearestDc).nearestDc, 4);
  });

  test('BadMsgNotification 16 syncs the clock and resends once', () async {
    final call = f.client.help.getNearestDc();
    final first = (await f.server.next(1)).single;
    expect(first.obj, isA<t.HelpGetNearestDc>());

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final serverMsgId = (nowSec + 600) << 32 | 1;
    f.server.push(
        msgId: serverMsgId,
        m: t.BadMsgNotification(
            badMsgId: first.msgId, badMsgSeqno: first.seqno, errorCode: 16));

    final second = (await f.server.next(1)).single;
    expect(second.obj, isA<t.HelpGetNearestDc>());
    expect(second.msgId, isNot(first.msgId));
    expect((second.msgId >> 32) - nowSec, inInclusiveRange(598, 603));
    expect(f.idGenerator.serverTicksOffset ~/ 10000000, inInclusiveRange(598, 602));

    f.server.push(m: t.RpcResult(reqMsgId: second.msgId, result: _nearest));
    final r = await call.timeout(const Duration(seconds: 2));
    expect((r.result as t.NearestDc).thisDc, 2);
  });

  test('a second BadMsgNotification 16/17 fails the call', () async {
    final call = f.client.help.getNearestDc();
    final first = (await f.server.next(1)).single;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    f.server.push(
        msgId: (nowSec - 400) << 32 | 1,
        m: t.BadMsgNotification(
            badMsgId: first.msgId, badMsgSeqno: first.seqno, errorCode: 17));
    final second = (await f.server.next(1)).single;
    // 17 (too high): the next id follows the corrected (slower) clock.
    expect((second.msgId >> 32) - nowSec, inInclusiveRange(-402, -397));
    f.server.push(
        msgId: (nowSec - 400) << 32 | 5,
        m: t.BadMsgNotification(
            badMsgId: second.msgId, badMsgSeqno: second.seqno, errorCode: 16));
    await expectLater(call, throwsA(isA<BadMessageException>()));
  });

  test('an injected plaintext BadMsgNotification 16 is ignored', () async {
    final logs = <String>[];
    // The fixture is built inside the zone so the receive listener's print
    // lands in [logs].
    await runZoned(() async {
      final g = Fixture();
      try {
        final offset = g.idGenerator.serverTicksOffset;
        final call = g.client.help.getNearestDc();
        final first = (await g.server.next(1)).single;
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        g.server.pushPlain(
            t.BadMsgNotification(
                badMsgId: first.msgId, badMsgSeqno: first.seqno, errorCode: 16),
            (nowSec + 100000) << 32 | 1);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(g.socket.sent.length, 1, reason: 'no resend');
        expect(g.idGenerator.serverTicksOffset, offset,
            reason: 'clock untouched');
        // The stream is still in sync: the real answer completes the call.
        g.server.push(m: t.RpcResult(reqMsgId: first.msgId, result: _nearest));
        final r = await call.timeout(const Duration(seconds: 2));
        expect((r.result as t.NearestDc).thisDc, 2);
      } finally {
        await g.close();
      }
    },
        zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => logs.add(line)));
    expect(logs, ['TVDIAG: tg dropped frame: unencrypted']);
  });

  test('other BadMsgNotification codes fail the call without resending',
      () async {
    final call = f.client.help.getNearestDc();
    final first = (await f.server.next(1)).single;
    f.server.push(
        m: t.BadMsgNotification(
            badMsgId: first.msgId, badMsgSeqno: first.seqno, errorCode: 32));
    await expectLater(call, throwsA(isA<BadMessageException>()));
    expect(f.socket.sent.length, 1);
  });

  test('unacked server messages get a standalone MsgsAck after 10 s',
      () async {
    final ackedId = f.server.nextServerMsgId();
    f.server.push(
        msgId: ackedId,
        seqno: 1, // odd = content-related, must be acked
        m: const t.NewSessionCreated(firstMsgId: 1, uniqueId: 2, serverSalt: 3));
    await Future<void>.delayed(const Duration(seconds: 9));
    expect(f.socket.sent, isEmpty, reason: 'nothing before 10 s');
    final sent = await f.server.next(1, timeout: const Duration(seconds: 3));
    final ack = sent.single.obj as t.MsgsAck;
    expect(ack.msgIds, [ackedId]);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
