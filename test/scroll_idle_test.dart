import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/gallery/widgets/scroll_idle.dart';

void main() {
  testWidgets('idle flips false on scroll start and true on scroll end', (
    tester,
  ) async {
    final readings = <bool>[];
    final controller = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: ScrollIdleTracker(
          child: Builder(
            builder: (context) {
              final idle = ScrollIdle.maybeOf(context);
              idle?.addListener(() => readings.add(idle.value));
              return ListView.builder(
                controller: controller,
                itemCount: 200,
                itemBuilder: (context, i) =>
                    SizedBox(height: 60, child: Text('$i')),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      ScrollIdle.maybeOf(tester.element(find.byType(ListView))),
      isNotNull,
    );

    await tester.fling(find.byType(ListView), const Offset(0, -800), 4000);
    // Mid-fling: a start notification must have already fired.
    expect(readings, isNotEmpty);
    expect(readings.first, isFalse);

    await tester.pumpAndSettle();
    // Once the fling fully settles, the tracker reports idle again.
    expect(readings.last, isTrue);
  });
}
