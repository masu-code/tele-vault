// README / landing-page screenshots from a DEMO library (Android emulator).
//
// Privacy / safety: nothing real is read. The library is built from the free
// sample photos in tool/demo/photos (Lorem Picsum / Unsplash License, see
// tool/demo/photos/CREDITS.md), pushed to the emulator by
// tool/demo/screenshots.ps1 into the app's own private files dir
// (`<app_flutter>/demo_photos`, with a manifest.json). The index, the feed,
// the profile, the backup state and the transfer queue are all overridden with
// generated demo data, so no screen touches Telegram, the real index, the real
// backup registry or the device gallery. SharedPreferences is an empty
// in-memory store and the backup registry lives in a scratch directory.
//
// Before writing anything the test refuses to run when the app's storage holds
// something that is not demo data (a Telegram session, thumbnails or previews
// that are not `demo-*`), i.e. when it is pointed at a real install. At the end
// it fails if the Telegram client got connected, and it deletes every file it
// created in app storage.
//
// Each screen is announced with a `TVSHOT:<name>` line on the log and then held
// still for a few seconds; the host script grabs the whole emulator screen
// (status bar included) with `adb screencap` at that moment.
//
// Run it with tool/demo/screenshots.ps1 (never against a physical phone).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tele_vault/core/backup/backup_registry.dart';
import 'package:tele_vault/core/telegram/client.dart';
import 'package:tele_vault/core/telegram/profile_service.dart' show TelegramProfile;
import 'package:tele_vault/core/thumbnail/preview_table.dart';
import 'package:tele_vault/core/thumbnail/thumb_encoder.dart' show resizeToThumbnail;
import 'package:tele_vault/core/thumbnail/thumb_prefetcher.dart' show defaultPreviewFromJpeg;
import 'package:tele_vault/core/thumbnail/thumb_store.dart';
import 'package:tele_vault/features/albums/screens/albums_screen.dart';
import 'package:tele_vault/features/backup/providers/backup_provider.dart';
import 'package:tele_vault/features/explorer/providers/index_provider.dart';
import 'package:tele_vault/features/explorer/screens/explorer_screen.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/providers/gallery_feed_provider.dart';
import 'package:tele_vault/features/gallery/screens/gallery_screen.dart';
import 'package:tele_vault/features/profile/providers/profile_provider.dart';
import 'package:tele_vault/features/transfer/providers/transfer_queue_provider.dart';
import 'package:tele_vault/models/album.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';
import 'package:tele_vault/models/folder.dart';
import 'package:tv_core/codecs.dart' show PreviewCodec;

import 'synthetic_gallery_test.dart' show pumpFor;

const bool _demoOk = bool.fromEnvironment('TV_DEMO_SCREENSHOTS');

/// How long each announced screen is held still for the host's screencap.
const Duration _hold = Duration(seconds: 5);

/// Demo item ids start with this; it is also how cleanup finds them.
const String _prefix = 'demo-';

// --------------------------------------------------------------------------
// Demo data
// --------------------------------------------------------------------------

class _Photo {
  _Photo(this.file, this.tag, this.video);
  final File file;
  final String tag;
  final bool video;
}

/// album title by manifest tag
const Map<String, String> _albumTitles = {
  'nature': 'Summer trip',
  'food': 'Good food',
  'animals': 'Pets',
  'city': 'City walks',
  'people': 'Friends',
};

String _two(int n) => n.toString().padLeft(2, '0');

/// Newest-first capture dates over the last four months, so the timeline shows
/// several month headers. [i] of [n]; months are relative to today.
DateTime _dateFor(int i, int n, DateTime now) {
  // Items per month, newest month first (sums to about n).
  final share = [0.22, 0.34, 0.26, 0.18];
  var left = i;
  for (var m = 0; m < share.length; m++) {
    final inMonth = m == share.length - 1
        ? n - (share.take(m).fold<int>(0, (a, s) => a + (n * s).round()))
        : (n * share[m]).round();
    if (left < inMonth) {
      final base = DateTime(now.year, now.month - m, 1);
      final maxDay = m == 0 ? now.day.clamp(1, 28) : 27;
      // spread the month's items over its days, newest first
      final day = (maxDay - (left * maxDay ~/ inMonth)).clamp(1, maxDay);
      final hour = 9 + (left * 7) % 11;
      final minute = (left * 17 + 5) % 60;
      return DateTime(base.year, base.month, day, hour, minute, (left * 13) % 60);
    }
    left -= inMonth;
  }
  return DateTime(now.year, now.month - 3, 1, 12);
}

String _cameraName(DateTime d, bool video) =>
    '${video ? 'VID' : 'IMG'}_${d.year}${_two(d.month)}${_two(d.day)}_'
    '${_two(d.hour)}${_two(d.minute)}${_two(d.second)}.${video ? 'mp4' : 'jpg'}';

// --------------------------------------------------------------------------
// Fakes: the app's own providers with the network cut off
// --------------------------------------------------------------------------

class _DemoIndex extends IndexNotifier {
  _DemoIndex(super.ref, FileIndex index) {
    state = IndexState(index: index);
  }

  @override
  Future<void> load() async {}

  @override
  Future<void> checkForRemoteChange() async {}

  @override
  bool get remoteSynced => false;
}

class _DemoProfile extends ProfileNotifier {
  _DemoProfile() {
    state = const ProfileState(
      profile: TelegramProfile(name: 'Alex Demo', phone: '15555550100'),
    );
  }
}

class _DemoBackup extends BackupNotifier {
  _DemoBackup(super.ref);

  @override
  Future<void> initRegistry() async {}

  @override
  Future<void> loadDeviceAlbums() async {
    state = state.copyWith(loaded: true);
  }
}

class _DemoQueue extends TransferQueueNotifier {
  _DemoQueue(super.ref);

  /// An upload batch in flight, as the account sheet shows it.
  void showUpload({
    required int total,
    required int done,
    required String name,
    required double progress,
  }) {
    state = TransferState(
      active: true,
      kind: TransferKind.upload,
      total: total,
      done: done,
      currentName: name,
      currentProgress: progress,
    );
  }
}

/// The three tabs inside the same navigation bar MainShell uses (MainShell
/// itself loads the real index and asks for permissions on start-up).
class _DemoShell extends StatefulWidget {
  const _DemoShell();

  @override
  State<_DemoShell> createState() => _DemoShellState();
}

class _DemoShellState extends State<_DemoShell> {
  int _index = 0;
  final Set<int> _visited = {0};
  static const _tabs = [GalleryScreen(), AlbumsScreen(), ExplorerScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < _tabs.length; i++)
            _visited.contains(i) ? _tabs[i] : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() {
          _index = i;
          _visited.add(i);
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            selectedIcon: Icon(Icons.photo_library),
            label: 'Gallery',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_album_outlined),
            selectedIcon: Icon(Icons.photo_album),
            label: 'Albums',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Files',
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------
// The test
// --------------------------------------------------------------------------

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('demo screenshots: gallery, viewer, albums, files, backup', (tester) async {
    expect(_demoOk, isTrue,
        reason: 'pass --dart-define=TV_DEMO_SCREENSHOTS=true (tool/demo/screenshots.ps1 does)');
    expect(Platform.isAndroid, isTrue);
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

    // ---- empty in-memory prefs and a scratch registry (never the real one) ----
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final tmp = await getTemporaryDirectory();
    final registryDir = Directory(p.join(tmp.path, 'tv_demo_registry'));
    if (registryDir.existsSync()) registryDir.deleteSync(recursive: true);
    registryDir.createSync(recursive: true);
    BackupRegistry.instance.debugUseDirectory(registryDir.path);
    await BackupRegistry.instance.init();
    await BackupRegistry.instance.recordHeadlessRun('uploaded 6 of 6 pending, 6 attempted (0 already in vault)');

    final support = await getApplicationSupportDirectory();
    final docs = await getApplicationDocumentsDirectory();
    final thumbDir = Directory(p.join(support.path, 'televault_thumbs'));
    final previewFile = File(p.join(support.path, 'tv_previews.bin'));
    final cacheDir = Directory(p.join(tmp.path, 'televault_cache'));

    // ---- guard: only ever run over an install that holds no real data ----
    expect(File(p.join(docs.path, 'tele_vault_session.json')).existsSync(), isFalse,
        reason: 'a Telegram session is present: this is not a clean demo install');
    if (thumbDir.existsSync()) {
      final foreign = thumbDir
          .listSync()
          .where((e) => !p.basename(e.path).startsWith(_prefix))
          .toList();
      expect(foreign, isEmpty, reason: 'thumbnails that are not demo data are present');
    }
    expect(previewFile.existsSync(), isFalse, reason: 'a previews table is present');

    // ---- the sample photos ----
    final photosDir = Directory(p.join(docs.path, 'demo_photos'));
    // Only what this test created; also runs when an expectation fails.
    void cleanup() {
      if (thumbDir.existsSync()) {
        for (final e in thumbDir.listSync(followLinks: false)) {
          if (e is File && p.basename(e.path).startsWith(_prefix)) e.deleteSync();
        }
      }
      ThumbStore.instance.resetForTesting();
      PreviewTable.instance.resetForTesting();
      try {
        previewFile.deleteSync();
      } catch (_) {}
      if (cacheDir.existsSync()) {
        for (final e in cacheDir.listSync(followLinks: false)) {
          if (e is Directory && p.basename(e.path).startsWith(_prefix)) {
            e.deleteSync(recursive: true);
          }
        }
      }
      try {
        registryDir.deleteSync(recursive: true);
      } catch (_) {}
      try {
        photosDir.deleteSync(recursive: true);
      } catch (_) {}
    }

    addTearDown(cleanup);

    final manifest = jsonDecode(File(p.join(photosDir.path, 'manifest.json')).readAsStringSync())
        as List<dynamic>;
    final photos = <_Photo>[
      for (final m in manifest.cast<Map<String, dynamic>>())
        _Photo(File(p.join(photosDir.path, m['file'] as String)), m['tag'] as String,
            (m['video'] as bool?) ?? false),
    ];
    expect(photos.length, greaterThanOrEqualTo(24));

    // ---- library: thumbnails in the thumb store, previews, full copies ----
    final now = DateTime.now();
    final files = <FileItem>[];
    final entries = <GalleryEntry>[];
    final idByTag = <String, List<String>>{};
    for (var i = 0; i < photos.length; i++) {
      final ph = photos[i];
      final id = '$_prefix${i.toString().padLeft(4, '0')}';
      final date = _dateFor(i, photos.length, now);
      final name = _cameraName(date, ph.video);
      final full = await ph.file.readAsBytes();
      final thumb = await resizeToThumbnail(full);
      expect(await ThumbStore.instance.put(id, thumb), isTrue, reason: 'thumb $id was refused');
      final hash = await defaultPreviewFromJpeg(thumb);
      expect(hash, isNotNull);
      var size = full.length;
      if (!ph.video) {
        // The viewer opens the cache copy: <temp>/televault_cache/<id>/<name>.
        final dest = File(p.join(cacheDir.path, id, name));
        dest.parent.createSync(recursive: true);
        dest.writeAsBytesSync(full);
      } else {
        size = 18 * 1024 * 1024 + i * 733 * 1024; // a believable clip size
      }
      final item = FileItem(
        id: id,
        name: name,
        folderId: null,
        totalSize: size,
        mimeType: ph.video ? 'video/mp4' : 'image/jpeg',
        createdAt: date,
        parts: [FilePart(messageId: -(i + 1), part: 0, size: size)],
        preview: PreviewCodec.toWire(hash!),
      );
      files.add(item);
      entries.add(GalleryEntry(fileItem: item));
      (idByTag[ph.tag] ??= []).add(id);
    }

    // ---- albums, folders, some non-media files for the Files tab ----
    final albums = <Album>[
      for (final e in _albumTitles.entries)
        if ((idByTag[e.key] ?? const []).length >= 3)
          Album(
            id: 'demo-album-${e.key}',
            name: e.value,
            fileIds: idByTag[e.key]!,
            createdAt: now.subtract(const Duration(days: 80)),
          ),
    ];
    final folders = <Folder>[
      const Folder(id: 'demo-folder-trips', name: 'Trips', parentId: null),
      const Folder(id: 'demo-folder-docs', name: 'Documents', parentId: null),
      const Folder(id: 'demo-folder-recipes', name: 'Recipes', parentId: null),
    ];
    FileItem doc(String n, String mime, int size, int daysAgo, {String? folder}) => FileItem(
          id: '${_prefix}doc-${n.hashCode.abs()}',
          name: n,
          folderId: folder,
          totalSize: size,
          mimeType: mime,
          createdAt: now.subtract(Duration(days: daysAgo)),
          parts: [FilePart(messageId: -(10000 + n.length), part: 0, size: size)],
        );
    files.insertAll(0, [
      doc('Quarterly report.pdf', 'application/pdf', 2412345, 9),
      doc('Project notes.txt', 'text/plain', 18234, 21),
      doc('Backup - October.zip', 'application/zip', 1738295123, 14),
      doc('Voice memo.m4a', 'audio/mp4', 4531922, 30),
    ]);
    final index = FileIndex(files: files, folders: folders, albums: albums);

    // ---- the app, rooted in the overridden providers ----
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          indexProvider.overrideWith((ref) => _DemoIndex(ref, index)),
          galleryFeedProvider.overrideWith((ref) async => entries),
          profileProvider.overrideWith((ref) => _DemoProfile()),
          backupProvider.overrideWith((ref) => _DemoBackup(ref)),
          transferQueueProvider.overrideWith((ref) => _DemoQueue(ref)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'TeleVault',
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF2AABEE),
              surface: Color(0xFF1C1C1E),
            ),
          ),
          home: const _DemoShell(),
        ),
      ),
    );
    for (var i = 0; i < 40 && find.byType(CustomScrollView).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(CustomScrollView), findsWidgets, reason: 'demo feed did not render');
    await pumpFor(tester, const Duration(seconds: 3)); // thumbnails decode

    Finder navLabel(String label) =>
        find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

    Future<void> shot(String name) async {
      await pumpFor(tester, const Duration(milliseconds: 800));
      // ignore: avoid_print
      print('TVSHOT:$name');
      await pumpFor(tester, _hold);
    }

    // 1. gallery
    await shot('gallery');

    // 2. viewer: open a landscape-ish photo from the first screenful
    final viewerEntry = entries.firstWhere(
      (e) => !e.isVideo && photos[entries.indexOf(e)].tag == 'nature' && entries.indexOf(e) > 2 && entries.indexOf(e) < 12,
    );
    await tester.tap(find.byKey(ValueKey<String>(viewerEntry.key)).first, warnIfMissed: false);
    await pumpFor(tester, const Duration(seconds: 4));
    await shot('viewer');
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await pumpFor(tester, const Duration(milliseconds: 1200));

    // 3. albums
    await tester.tap(navLabel('Albums'));
    await pumpFor(tester, const Duration(seconds: 3));
    await shot('albums');

    // 4. files
    await tester.tap(navLabel('Files'));
    await pumpFor(tester, const Duration(seconds: 3));
    await shot('files');

    // 5. account sheet, then the same sheet with an upload running
    await tester.tap(navLabel('Gallery'));
    await pumpFor(tester, const Duration(seconds: 2));
    await tester.tap(find.byType(CircleAvatar).first);
    await pumpFor(tester, const Duration(seconds: 3));
    await shot('account');
    final container = ProviderScope.containerOf(tester.element(find.byType(_DemoShell)));
    (container.read(transferQueueProvider.notifier) as _DemoQueue).showUpload(
      total: 42,
      done: 17,
      name: _cameraName(_dateFor(3, photos.length, now), false),
      progress: 0.6,
    );
    await pumpFor(tester, const Duration(seconds: 1));
    await shot('backup');

    // No layout/overflow errors. The only tolerated message is the framework's
    // debug-mode warning that AccountSheet's cards (a ListTile inside a
    // DecoratedBox) hide their ink splash: it is not a visual problem.
    Object? error;
    while ((error = tester.takeException()) != null) {
      expect(error.toString(), contains('ListTile background color or ink splashes'),
          reason: 'unexpected framework error while rendering the demo screens');
    }
    // Network guard: nothing in this test may have connected the real client.
    final networkTouched = TelegramService.instance.isConnected;

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(networkTouched, isFalse, reason: 'demo screenshots connected to Telegram');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
