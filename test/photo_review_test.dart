import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_uploader/photo_review.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('pinch paints beyond initial photo bounds in a $size viewport',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
              home: PhotoReview(
            name: 'photo.jpg',
            sourcePath: 'source',
            uploadPath: 'upload',
            status: '전송 사진',
            imageBuilder: (path) => SizedBox(
                width: 160,
                height: 90,
                child: ColoredBox(
                    key: ValueKey('image-$path'),
                    color: const Color(0xFFFF0000))),
          ))));
      await tester.pumpAndSettle();
      final photo = find.byKey(const ValueKey('image-upload'));
      final original = tester.getRect(photo);
      final viewport = tester.getRect(find.byType(InteractiveViewer));
      final expanded = tester.getRect(find.ancestor(
          of: find.byType(InteractiveViewer), matching: find.byType(Expanded)));
      expect(viewport, expanded,
          reason: 'Clip and gesture bounds must fill the review area');
      final center = original.center;
      final first =
          await tester.startGesture(center - const Offset(25, 0), pointer: 1);
      final second =
          await tester.startGesture(center + const Offset(25, 0), pointer: 2);
      await tester.pump();
      await first.moveTo(center - const Offset(40, 0));
      await second.moveTo(center + const Offset(40, 0));
      await tester.pump();
      await first.moveTo(center - const Offset(85, 0));
      await second.moveTo(center + const Offset(85, 0));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      final sample = Offset(original.right + 15, original.center.dy);
      expect(original.contains(sample), isFalse);
      expect(viewport.contains(sample), isTrue);
      // Verify actual rendered pixels, not just the transform: the old small
      // viewport scaled the image but clipped this newly enlarged portion away.
      final boundary = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final pixel = await tester.runAsync(() async {
        final snapshot = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes =
              (await snapshot.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          final point = boundary.globalToLocal(sample);
          final offset =
              (point.dy.floor() * snapshot.width + point.dx.floor()) * 4;
          return List.generate(4, (index) => bytes.getUint8(offset + index));
        } finally {
          snapshot.dispose();
        }
      });
      expect(pixel, [255, 0, 0, 255]);

      // Switching to the original must reset the zoom for that different file.
      await tester.tap(find.text('원본'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const ValueKey('image-source'))).size,
          original.size);
      expect(tester.takeException(), isNull);
    });
  }
}
