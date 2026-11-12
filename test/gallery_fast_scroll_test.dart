import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/widgets/fast_scrollbar.dart';
import 'package:tele_vault/features/gallery/widgets/gallery_tile.dart';
import 'package:tele_vault/features/gallery/widgets/scroll_idle.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

// Reproduces the exact structure gallery_screen.dart builds — a
// ScrollIdleTracker wrapping a FastScrollbar wrapping a CustomScrollView of
// month-grouped SliverGrids of GalleryTiles — so a fast fling exercises the
// same tile creation/destruction churn that triggered a "Null check operator
// used on a null value" crash on-device. Cloud-only entries (fileItem, no
// AssetEntity) avoid needing the photo_manager plugin, which isn't available
// in a plain widget test.

FileItem _file(String id) => FileItem(
  id: id,
  name: '$id.jpg',
  folderId: null,
  totalSize: 100,
  mimeType: 'image/jpeg',
  createdAt: DateTime(2026, 1, 1),
  parts: const [FilePart(messageId: 1, part: 0, size: 100)],
);

void main() {
  testWidgets('fast fling through many GalleryTiles throws nothing', (
    tester,
  ) async {
    final entries = List.generate(
      400,
      (i) => GalleryEntry(fileItem: _file('f$i')),
    );
    final controller = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScrollIdleTracker(
            child: FastScrollbar(
              controller: controller,
              child: CustomScrollView(
                controller: controller,
                slivers: [
                  SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 120,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => GalleryTile(
                        key: ValueKey(entries[i].key),
                        entry: entries[i],
                        onTap: () {},
                        onLongPress: () {},
                      ),
                      childCount: entries.length,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Several fast flings in both directions — the exact motion that
    // triggered the on-device crash, each one building and destroying many
    // tiles per frame.
    for (var i = 0; i < 8; i++) {
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, -2500),
        8000,
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.takeException(),
        isNull,
        reason: 'threw during downward fling #$i',
      );
    }
    for (var i = 0; i < 8; i++) {
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 2500),
        8000,
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.takeException(),
        isNull,
        reason: 'threw during upward fling #$i',
      );
    }

    // Let any in-flight flings/animations settle without waiting for the
    // (network-bound, never-resolving in this test) thumbnail futures.
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
