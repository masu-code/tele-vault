import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/providers/gallery_feed_provider.dart';
import 'package:tele_vault/features/gallery/providers/thumb_prefetch_provider.dart';
import 'package:tele_vault/features/gallery/screens/gallery_screen.dart';
import 'package:tele_vault/features/gallery/services/gallery_feed_service.dart';
import 'package:tele_vault/features/profile/widgets/floating_profile_header.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

// The real GalleryScreen over a cloud-only feed (no photo_manager needed):
// every month section must render its title, and the first one must sit
// below the floating "Gallery" header, not under it.

String _two(int n) => n.toString().padLeft(2, '0');

FileItem _file(int i, DateTime taken) => FileItem(
      id: 'f$i',
      name: 'IMG_${taken.year}${_two(taken.month)}${_two(taken.day)}_120000.jpg',
      folderId: null,
      totalSize: 100,
      mimeType: 'image/jpeg',
      // Upload time: one June 2026 session for everything.
      createdAt: DateTime.utc(2026, 6, 20, 22, 0, i),
      parts: const [FilePart(messageId: 1, part: 0, size: 100)],
    );

void main() {
  testWidgets('every month section shows its title, the first one visibly',
      (tester) async {
    final year = DateTime.now().year;
    final months = [
      DateTime(year, 1, 10), // current year: header omits the year
      DateTime(2024, 3, 10),
      DateTime(2021, 7, 4),
      DateTime(2019, 1, 20),
      DateTime(2016, 11, 2),
    ];
    var i = 0;
    final feed = sortNewestFirst([
      for (final m in months)
        for (var k = 0; k < 30; k++)
          GalleryEntry(fileItem: _file(i++, m.add(Duration(hours: k)))),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          thumbPrefetchBindingProvider.overrideWith((ref) {}),
          galleryFeedProvider.overrideWith((ref) async => feed),
        ],
        child: const MediaQuery(
          data: MediaQueryData(
            size: Size(400, 800),
            padding: EdgeInsets.only(top: 24),
          ),
          child: MaterialApp(home: GalleryScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final labels = [
      for (final m in months) monthHeaderLabel(DateTime(m.year, m.month), year),
    ];
    expect(labels.first, 'January');
    expect(labels[1], year == 2024 ? 'March' : 'March 2024');

    // The first title is on screen at the top and clears the floating header.
    final first = find.text(labels.first);
    expect(first, findsOneWidget);
    final headerBottom =
        tester.getRect(find.byType(FloatingProfileHeader)).bottom;
    expect(tester.getRect(first).top, greaterThanOrEqualTo(headerBottom));

    // Every other section's title is reached by scrolling, exactly once.
    for (final label in labels.skip(1)) {
      await tester.scrollUntilVisible(
        find.text(label),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('June 2026'), findsNothing,
        reason: 'no section is filed under the upload month');
  });
}
