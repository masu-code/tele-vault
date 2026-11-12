import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/diag/tv_stats.dart';
import 'package:tele_vault/core/thumbnail/preview_table.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/widgets/gallery_tile.dart';
import 'package:tele_vault/features/gallery/widgets/preview_placeholder.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';
import 'package:tv_core/codecs.dart';

// Widget tests have no path_provider: ThumbStore never becomes ready, the
// PreviewTable is memory-only and the prefetcher stays inert. That is exactly
// the "degrade gracefully" case the tile has to survive.

FileItem _file(String id, {String mime = 'image/jpeg'}) => FileItem(
  id: id,
  name: '$id.jpg',
  folderId: null,
  totalSize: 100,
  mimeType: mime,
  createdAt: DateTime(2026, 1, 1),
  parts: const [FilePart(messageId: 1, part: 0, size: 100)],
);

/// ThumbHash of a solid colour.
Uint8List _solidHash(int r, int g, int b) {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = 255;
  }
  return PreviewCodec.encodeRgba(rgba, 8, 8)!;
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 120, height: 120, child: child)),
);

Color _baseColor(WidgetTester tester) {
  final box = tester.widget<ColoredBox>(
    find
        .descendant(
          of: find.byType(GalleryTile),
          matching: find.byType(ColoredBox),
        )
        .first,
  );
  return box.color;
}

void main() {
  setUp(() {
    TvStats.reset();
    PreviewImageCache.instance.clear();
  });

  testWidgets('a tile with a preview paints its colour with no store file', (
    tester,
  ) async {
    const id = 'tile-test-preview';
    PreviewTable.instance.put(id, _solidHash(200, 50, 50));

    await tester.pumpWidget(
      _host(
        GalleryTile(
          entry: GalleryEntry(fileItem: _file(id)),
          onTap: () {},
          onLongPress: () {},
        ),
      ),
    );

    final c = _baseColor(tester);
    expect(c, isNot(const Color(kTileFallbackColor)));
    expect((c.r * 255).round(), closeTo(200, 4));
    expect((c.g * 255).round(), closeTo(50, 4));
    expect((c.b * 255).round(), closeTo(50, 4));
    expect(TvStats.tileBlankFrames, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tile with nothing repaints when its preview is put later', (
    tester,
  ) async {
    const id = 'tile-test-late-preview';
    await tester.pumpWidget(
      _host(
        GalleryTile(
          entry: GalleryEntry(fileItem: _file(id)),
          onTap: () {},
          onLongPress: () {},
        ),
      ),
    );
    expect(_baseColor(tester), const Color(kTileFallbackColor));
    expect(find.byType(PreviewImage), findsNothing);

    // Another key first: it must not repaint this tile.
    PreviewTable.instance.put('tile-test-other', _solidHash(1, 2, 3));
    await tester.pump();
    expect(_baseColor(tester), const Color(kTileFallbackColor));

    PreviewTable.instance.put(id, _solidHash(200, 50, 50));
    // The bump is a microtask that runs after the frame of the first pump;
    // the second pump paints the setState it causes.
    await tester.pump();
    await tester.pump();

    final c = _baseColor(tester);
    expect(c, isNot(const Color(kTileFallbackColor)));
    expect((c.r * 255).round(), closeTo(200, 4));
    expect(find.byType(PreviewImage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('PreviewTable.revision bumps once per batch of puts', () async {
    final table = PreviewTable.withFile(() async => throw UnsupportedError('memory'));
    var bumps = 0;
    table.revision.addListener(() => bumps++);
    table.put('a', _solidHash(10, 20, 30));
    table.put('b', _solidHash(30, 20, 10));
    table.putAll({'c': _solidHash(60, 60, 60)});
    expect(bumps, 0);
    await Future<void>.delayed(Duration.zero);
    expect(bumps, 1);
    // Same content again: nothing changed, no bump.
    table.put('a', _solidHash(10, 20, 30));
    await Future<void>.delayed(Duration.zero);
    expect(bumps, 1);
    table.put('d', _solidHash(90, 90, 90));
    await Future<void>.delayed(Duration.zero);
    expect(bumps, 2);
  });

  testWidgets('a decoded preview is painted as an image', (tester) async {
    const id = 'tile-test-decoded';
    final hash = _solidHash(30, 120, 200);
    PreviewTable.instance.put(id, hash);
    // Engine callbacks do not complete under the test's fake clock.
    final ui = await tester.runAsync(
      () => PreviewImageCache.instance.load(id, hash),
    );
    expect(ui, isNotNull);
    ui!.dispose();

    await tester.pumpWidget(
      _host(
        GalleryTile(
          entry: GalleryEntry(fileItem: _file(id)),
          onTap: () {},
          onLongPress: () {},
        ),
      ),
    );

    expect(find.byType(PreviewImage), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('without path_provider, preview or file nothing throws', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        GalleryTile(
          entry: GalleryEntry(fileItem: _file('tile-test-nothing')),
          onTap: () {},
          onLongPress: () {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(_baseColor(tester), const Color(kTileFallbackColor));
    // The one case the counter exists to catch.
    expect(TvStats.tileBlankFrames, 1);
    expect(find.byType(PreviewImage), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('the cloud badge and the video marker show on a plain tile', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        GalleryTile(
          entry: GalleryEntry(
            fileItem: _file('tile-test-video', mime: 'video/mp4'),
          ),
          onTap: () {},
          onLongPress: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
  });

  testWidgets('selecting one item builds exactly one tile', (tester) async {
    final entries = List.generate(
      20,
      (i) => GalleryEntry(fileItem: _file('sel$i')),
    );
    final selection = ValueNotifier<Set<String>>(const {});
    addTearDown(selection.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GridView.count(
            crossAxisCount: 4,
            children: [
              for (final e in entries)
                SelectionScopedTile(
                  key: ValueKey(e.key),
                  entry: e,
                  selection: selection,
                  onTap: () {},
                  onLongPress: () {},
                ),
            ],
          ),
        ),
      ),
    );
    expect(TvStats.tileBuilds, greaterThan(1));

    TvStats.reset();
    selection.value = {'sel3'};
    await tester.pump();
    expect(TvStats.tileBuilds, 1);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    TvStats.reset();
    selection.value = {'sel3', 'sel7'};
    await tester.pump();
    expect(TvStats.tileBuilds, 1);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));

    TvStats.reset();
    selection.value = const {};
    await tester.pump();
    expect(TvStats.tileBuilds, 2);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  test('PreviewImageCache keeps at most `capacity` images', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final cache = PreviewImageCache(capacity: 3);
    final hash = _solidHash(10, 10, 10);
    for (var i = 0; i < 6; i++) {
      final img = await cache.load('k$i', hash);
      expect(img, isNotNull);
      img!.dispose();
    }
    expect(cache.length, 3);
    expect(cache.cloneIfCached('k0'), isNull);
    final last = cache.cloneIfCached('k5');
    expect(last, isNotNull);
    last!.dispose();
    cache.clear();
  });
}
