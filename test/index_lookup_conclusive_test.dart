import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:t/t.dart' as t;
import 'package:tele_vault/core/index/index_cache.dart';
import 'package:tele_vault/core/index/index_remote.dart';
import 'package:tele_vault/core/index/index_service.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

/// I3: "no index" may only be concluded from a successful marker search or a
/// history scan that read all of Saved Messages. A failed search plus a scan
/// that stopped early (cap, error) must fail the load, so no save can fork a
/// second index message.

t.MessagesMessagesBase _page(List<t.MessageBase> messages) => t.MessagesMessages(
      messages: messages,
      topics: const [],
      chats: const [],
      users: const [],
    );

t.Result<t.MessagesMessagesBase> _ok(List<t.MessageBase> messages) =>
    t.Result.ok(_page(messages));

t.Result<t.MessagesMessagesBase> _err(String message) =>
    t.Result.error(t.RpcError(errorCode: 400, errorMessage: message));

/// Saved Messages history of [total] plain (non-index) messages, newest id
/// first, served 100 per page like `messages.getHistory`.
class FakeLookup implements IndexLookupRpc {
  FakeLookup({required this.searchResult, this.total = 0, this.failAfterPages});

  /// Null: the search throws (transport failure).
  final t.Result<t.MessagesMessagesBase>? searchResult;
  final int total;

  /// The history call after this many successful pages returns an error.
  final int? failAfterPages;

  int searches = 0;
  int historyCalls = 0;

  @override
  Future<t.Result<t.MessagesMessagesBase>> search() async {
    searches++;
    final r = searchResult;
    if (r == null) throw const SocketException('network down');
    return r;
  }

  @override
  Future<t.Result<t.MessagesMessagesBase>> getMessage(int id) async => _ok(const []);

  @override
  Future<t.Result<t.MessagesMessagesBase>> history(int offsetId) async {
    final call = historyCalls++;
    final fail = failAfterPages;
    if (fail != null && call >= fail) return _err('INTERNAL_SERVER_ERROR');
    // Ids run total..1; offsetId 0 = newest.
    final start = offsetId == 0 ? total : offsetId - 1;
    final ids = [for (var id = start; id >= 1 && id > start - 100; id--) id];
    return _ok([for (final id in ids) t.MessageEmpty(id: id)]);
  }
}

/// [IndexRemote] whose load is the real lookup over [FakeLookup], and whose
/// write records index-message creations.
class LookupRemote implements IndexRemote {
  int creates = 0;
  int writes = 0;

  @override
  Future<RemoteIndexSnapshot> load(RemoteLoadArgs args) => remoteLoad(args);

  @override
  Future<RemoteWriteResult> write(RemoteWriteArgs args) async {
    writes++;
    if (args.messageId == null) creates++;
    return RemoteWriteResult.written(messageId: 900 + creates, documentId: 5000 + writes);
  }

  @override
  Future<List<int>?> existingMessageIds(List<int> messageIds) async => messageIds;

  @override
  Future<void> deleteMessages(List<int> messageIds) async {}

  @override
  Future<int?> documentIdOf(int messageId) async => null;

  @override
  Future<List<TransferableTypedData>> scanAllSnapshots(int maxMessages) async => const [];
}

FileItem _file(String id) => FileItem(
      id: id,
      name: 'n_$id',
      folderId: null,
      totalSize: 10,
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026),
      parts: [const FilePart(messageId: 1, part: 0, size: 10)],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LookupRemote remote;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('index_lookup_test');
    remote = LookupRemote();
  });

  tearDown(() async {
    indexLookupRpc = const IndexLookupRpc();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  IndexService newService() =>
      IndexService.forTesting(remote: remote, cache: IndexCache.inDirectory(dir));

  test('a search error and an interrupted scan fail the load; save refuses to create',
      () async {
    indexLookupRpc = FakeLookup(
      searchResult: _err('INTERNAL'),
      total: 800,
      failAfterPages: 3,
    );
    final s = newService();
    await expectLater(s.load(), throwsA(isA<IndexException>()));
    expect(s.synced, isFalse);

    await expectLater(
      s.save(FileIndex(files: [_file('new')])),
      throwsA(isA<IndexException>()),
    );
    expect(remote.writes, 0);
    expect(remote.creates, 0, reason: 'never a second index message');
  });

  test('a failed search plus a scan that hits the cap without the marker fails the load',
      () async {
    final lookup = FakeLookup(searchResult: null, total: 20000);
    indexLookupRpc = lookup;
    final s = newService();
    await expectLater(
      s.load(),
      throwsA(isA<IndexException>().having(
          (e) => e.message, 'message', contains('without reaching the start'))),
    );
    expect(lookup.searches, 1);
    expect(lookup.historyCalls, greaterThan(40), reason: 'the deep scan ran to its cap');

    await expectLater(
      s.save(FileIndex(files: [_file('new')])),
      throwsA(isA<IndexException>()),
    );
    expect(remote.creates, 0);
  });

  test('a clean empty search result still creates the first index', () async {
    indexLookupRpc = FakeLookup(searchResult: _ok(const []), total: 150);
    final s = newService();
    final loaded = await s.load();
    expect(loaded.files, isEmpty);
    expect(s.synced, isTrue);

    await s.save(loaded.addFile(_file('a')));
    expect(remote.creates, 1);
  });

  test('a clean empty search is trusted even when the history is longer than the cap',
      () async {
    indexLookupRpc = FakeLookup(searchResult: _ok(const []), total: 20000);
    final s = newService();
    final loaded = await s.load();
    expect(loaded.files, isEmpty);
    await s.save(loaded.addFile(_file('a')));
    expect(remote.creates, 1);
  });

  test('a failed search with a scan that reads all of history concludes no index',
      () async {
    indexLookupRpc = FakeLookup(searchResult: _err('INTERNAL'), total: 250);
    final s = newService();
    final loaded = await s.load();
    expect(loaded.files, isEmpty);
    await s.save(loaded.addFile(_file('a')));
    expect(remote.creates, 1);
  });
}
