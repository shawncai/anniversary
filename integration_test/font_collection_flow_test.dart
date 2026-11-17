// Isolated emulator/simulator only. Uses synthetic gallery photos and real bridges.
import 'dart:convert';
import 'dart:io';
import 'package:anniversary/ui/event_editor.dart';
import 'package:anniversary/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'app_flow_test.dart' as flow;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Source Han Sans, soft album palette and creation-only collection',
    (tester) async {
      final c = await flow.startRealApp(tester, 'font-collection');
      try {
        final fonts =
            jsonDecode(await rootBundle.loadString('FontManifest.json'))
                as List;
        final han = fonts.cast<Map>().singleWhere(
          (f) => f['family'] == ShiriTheme.fontFamily,
        );
        expect((han['fonts'] as List).length, 4);
        for (final font in han['fonts'] as List) {
          final data = await rootBundle.load((font as Map)['asset'] as String);
          expect(data.buffer.asUint8List(data.offsetInBytes, 4), [
            79,
            84,
            84,
            79,
          ]);
        }
        await flow.tab(tester, '相册');
        final theme = Theme.of(
          tester.element(find.byKey(const ValueKey('event-selector'))),
        );
        expect(theme.colorScheme.primary, ShiriTheme.albumAccent);
        expect(theme.textTheme.bodyMedium?.fontFamily, ShiriTheme.fontFamily);
        expect(c.state.photos.length, 3);
        await tester.tap(find.byTooltip('管理纪念日'));
        await flow.pumpInputFrames(tester);
        await tester.tap(find.text('添加纪念日'));
        await flow.pumpInputFrames(tester);
        await tester.enterText(
          find.byKey(const ValueKey('anniversary-title')),
          '首次归集验证',
        );
        await flow.setDate(tester, DateTime(2018, 6, 18));
        await flow.saveEditor(tester);
        await flow.waitUntil(
          tester,
          () =>
              c.photos.length == 4 &&
              !c.scanningPhotos &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(c.state.photos.length, 7);
        // This changed range includes a fifth fixture. Editing must not collect it.
        await tester.tap(find.byTooltip('管理纪念日'));
        await flow.pumpInputFrames(tester);
        await tester.tap(find.text('编辑纪念日'));
        await flow.pumpInputFrames(tester);
        await flow.setDate(tester, DateTime(2018, 6, 19));
        await flow.saveEditor(tester);
        await flow.waitUntil(
          tester,
          () =>
              c.selected!.startDate.day == 19 &&
              find.byType(EventEditor).evaluate().isEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        await flow.tab(tester, '纪念日');
        await flow.tab(tester, '相册');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await flow.pumpInputFrames(tester);
        expect(
          c.photos.length,
          4,
          reason:
              'Editing, reopening and resume must not import the fifth fixture',
        );
        await tester.tap(find.text('归集'));
        await flow.waitUntil(
          tester,
          () =>
              c.photos.length == 5 &&
              !c.scanningPhotos &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(c.state.photos.length, 8);
        await c.select('test-together');
        await flow.tab(tester, '纪念日');
        if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
        await flow.capture(tester, binding, '01-home-font');
        await flow.tab(tester, '相册');
        await flow.capture(tester, binding, '02-album-palette');
        await tester.tap(find.text('多选'));
        await flow.pumpInputFrames(tester);
        await tester.tap(find.text('全选'));
        await flow.pumpInputFrames(tester);
        await flow.capture(tester, binding, '03-selection-palette');
        await tester.tap(find.byType(BackButton));
        await flow.pumpInputFrames(tester);
        await flow.tab(tester, '数据');
        await flow.capture(tester, binding, '04-data-font');
        await c.syncWidgets();
        expect(c.widgetError, isNull);
        binding.reportData = {
          ...?binding.reportData,
          'fontCollection': {
            'completed': true,
            'platform': Platform.operatingSystem,
            'fontFamily': ShiriTheme.fontFamily,
            'bundledWeights': 4,
            'creationCollected': 4,
            'afterEditAndReentry': 4,
            'afterManualCollection': 5,
            'originalPhotosPreserved': true,
            'widgetSnapshot': true,
          },
        };
        expect(tester.takeException(), isNull);
      } finally {
        await flow.closeRealApp(tester, c);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
