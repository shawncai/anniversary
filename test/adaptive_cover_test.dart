import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:anniversary/ui/adaptive_cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _luminance(Color color) {
  double linear(double c) =>
      c <= .04045 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();
  return .2126 * linear(color.r) +
      .7152 * linear(color.g) +
      .0722 * linear(color.b);
}

double _contrast(Color a, Color b) {
  final first = _luminance(a), second = _luminance(b);
  return (math.max(first, second) + .05) / (math.min(first, second) + .05);
}

void main() {
  for (final background in [
    'white',
    'black',
    'title-stripe',
    'translated-title',
  ]) {
    testWidgets('$background image keeps the actual title area readable', (
      tester,
    ) async {
      late Directory directory;
      late File file;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('shiri-cover-test-');
        file = File('${directory.path}/input.png');
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 320, 340),
          Paint()..color = background == 'white' ? Colors.white : Colors.black,
        );
        // The visible title is at y=24, above the old fixed .15 sampling area.
        if (background == 'title-stripe' || background == 'translated-title')
          canvas.drawRect(
            Rect.fromLTWH(
              0,
              background == 'translated-title' ? 130 : 10,
              320,
              37,
            ),
            Paint()..color = Colors.white,
          );
        final picture = recorder.endRecording();
        final image = await picture.toImage(320, 340);
        try {
          final encoded = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await file.writeAsBytes(encoded!.buffer.asUint8List());
        } finally {
          image.dispose();
          picture.dispose();
        }
      });
      var analyzed = false;
      final titleKey = GlobalKey();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: AdaptiveCover(
                    file: file,
                    height: 340,
                    textKeys: [titleKey],
                    onInk: (_) => analyzed = true,
                    builder: (context, color) => Padding(
                      padding: const EdgeInsets.only(left: 22, top: 24),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Transform.translate(
                          offset: Offset(
                            0,
                            background == 'translated-title' ? 120 : 0,
                          ),
                          child: Text(
                            '纪念日',
                            key: titleKey,
                            style: TextStyle(color: color),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 120 && !analyzed; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(analyzed, true);
        await tester.pumpAndSettle();
        final text = tester.widget<Text>(find.byKey(titleKey));
        var actualBackground = background == 'black'
            ? Colors.black
            : Colors.white;
        final decorations = tester.widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(AdaptiveCover),
            matching: find.byType(DecoratedBox),
          ),
        );
        for (final decorated in decorations) {
          final decoration = decorated.decoration;
          if (decoration is BoxDecoration &&
              decoration.gradient is LinearGradient) {
            final overlay =
                (decoration.gradient as LinearGradient).colors.first;
            actualBackground = Color.alphaBlend(overlay, actualBackground);
          }
        }
        expect(
          _contrast(text.style!.color!, actualBackground),
          greaterThanOrEqualTo(4.5),
          reason:
              'The actual title pixels, including a bright strip, must meet the contrast target',
        );
        if (background == 'white')
          expect(text.style!.color, const Color(0xFF141414));
        if (background == 'black') expect(text.style!.color, Colors.white);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => directory.delete(recursive: true));
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      }
    });
  }
}
