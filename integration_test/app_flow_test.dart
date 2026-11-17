// Runs the real app and native bridge. The host injects an isolated test library
// before launch; this test neither mocks the bridge nor bundles photo assets.
import 'dart:io';

import 'package:anniversary/main.dart' as app;
import 'package:anniversary/core/calendar.dart';
import 'package:anniversary/ui/app_controller.dart';
import 'package:anniversary/ui/app_shell.dart';
import 'package:anniversary/ui/photo_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/event_editor_test.dart' as date_entry;

// Native Android IME/cursor/insets can keep scheduling frames indefinitely.
// Pump a fixed number of frames, then assert widget/business state explicitly.
Future<void> pumpInputFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  String? reason,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), true, reason: reason);
  await pumpInputFrames(tester);
}

Future<void> tab(WidgetTester tester, String name) async {
  await tester.tap(
    find.descendant(
      of: find.byType(BottomNavigationBar),
      matching: find.byTooltip(name),
    ),
  );
  await pumpInputFrames(tester);
  await waitUntil(
    tester,
    () =>
        !tester
            .widget<AppShell>(find.byType(AppShell))
            .controller
            .scanningPhotos &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty,
  );
}

Future<void> setDate(WidgetTester tester, DateTime date) async {
  debugPrint('SHIRI_STAGE datePicker.calendar.open.$date');
  final input = find.byKey(const ValueKey('anniversary-start-date'));
  await tester.tap(input.evaluate().isEmpty ? find.text('首次日期') : input);
  await pumpInputFrames(tester);
  final picker = find.byType(DatePickerDialog);
  expect(picker, findsOneWidget);
  final calendar = find.descendant(
    of: picker,
    matching: find.byType(CalendarDatePicker),
  );
  expect(calendar, findsOneWidget);
  final initial = tester.widget<CalendarDatePicker>(calendar).initialDate!;
  final labels = MaterialLocalizations.of(tester.element(picker));
  if (initial.year != date.year ||
      find.byType(YearPicker).evaluate().isNotEmpty) {
    debugPrint('SHIRI_STAGE datePicker.calendar.year.${date.year}');
    if (find.byType(YearPicker).evaluate().isEmpty) {
      await tester.tap(
        find.descendant(
          of: calendar,
          matching: find.text(labels.formatMonthYear(initial)),
        ),
      );
      await pumpInputFrames(tester);
    }
    final years = find.byType(YearPicker);
    expect(years, findsOneWidget);
    final targetYear = find.descendant(
      of: years,
      matching: find.byKey(ValueKey<int>(date.year)),
    );
    await tester.scrollUntilVisible(
      targetYear,
      date.year < initial.year ? -200 : 200,
      scrollable: find
          .descendant(of: years, matching: find.byType(Scrollable))
          .first,
      maxScrolls: 80,
    );
    await tester.tap(targetYear);
    await pumpInputFrames(tester);
    expect(years, findsNothing);
  }
  final monthDelta = date.month - initial.month;
  final monthArrow = monthDelta < 0
      ? labels.previousMonthTooltip
      : labels.nextMonthTooltip;
  for (var step = 0; step < monthDelta.abs(); step++) {
    debugPrint('SHIRI_STAGE datePicker.calendar.month-step.${step + 1}');
    await tester.tap(find.byTooltip(monthArrow));
    await pumpInputFrames(tester);
  }
  expect(
    find.descendant(
      of: calendar,
      matching: find.text(labels.formatMonthYear(date)),
    ),
    findsOneWidget,
  );
  final targetDay = find.descendant(
    of: calendar,
    matching: find.byKey(ValueKey<DateTime>(DateUtils.dateOnly(date))),
  );
  expect(targetDay, findsOneWidget);
  debugPrint('SHIRI_STAGE datePicker.calendar.day.${date.day}');
  await tester.tap(targetDay);
  await pumpInputFrames(tester);
  expect(
    find.descendant(
      of: targetDay,
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true,
      ),
    ),
    findsOneWidget,
    reason: 'The actual target date cell must be selected before confirmation',
  );
  debugPrint('SHIRI_STAGE datePicker.calendar.confirm');
  await tester.tap(
    find.descendant(of: picker, matching: find.text(labels.okButtonLabel)),
  );
  await pumpInputFrames(tester);
  expect(picker, findsNothing);
  final expectedLabel =
      '${date.year.toString().padLeft(4, '0')}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  expect(
    find.text(expectedLabel),
    findsOneWidget,
    reason: 'The editor must show the date returned by the actual dialog',
  );
  debugPrint('SHIRI_STAGE datePicker.calendar.closed.$expectedLabel');
}

Future<void> saveEditor(WidgetTester tester) async {
  debugPrint('SHIRI_STAGE editor.keyboard.hide');
  FocusManager.instance.primaryFocus?.unfocus();
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  final reminder = find.byType(SwitchListTile);
  if (reminder.evaluate().isNotEmpty &&
      tester.widget<SwitchListTile>(reminder).value) {
    await tester.ensureVisible(reminder);
    await tester.tap(reminder);
    await pumpInputFrames(tester);
  }
  final save = find.widgetWithText(FilledButton, '保存');
  await tester.ensureVisible(save);
  await pumpInputFrames(tester);
  debugPrint('SHIRI_STAGE editor.save.tap');
  await tester.tap(save);
}

Future<void> capture(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  String name,
) async {
  if (find.byType(Image).evaluate().isNotEmpty) {
    await waitUntil(
      tester,
      () => find
          .byWidgetPredicate(
            (widget) => widget is RawImage && widget.image != null,
          )
          .evaluate()
          .isNotEmpty,
      reason: 'A real archived photo must decode before screenshot capture',
    );
  }
  // Allow the actual cover-region analysis and platform surface conversion to
  // paint their result, instead of capturing the safe initial loading scrim.
  await tester.pump(const Duration(milliseconds: 600));
  await pumpInputFrames(tester);
  debugPrint('SHIRI_STAGE screenshot.$name.start');
  await binding.takeScreenshot(name);
  debugPrint('SHIRI_STAGE screenshot.$name.complete');
}

Future<AppController> startRealApp(
  WidgetTester tester,
  String stage, {
  int expectedEvents = 3,
}) async {
  debugPrint('SHIRI_STAGE $stage.bootstrap.start');
  app.main();
  await waitUntil(
    tester,
    () => find.byType(AppShell).evaluate().isNotEmpty,
    reason: 'Native paths/bootstrap must open the injected local library',
  );
  final controller = tester.widget<AppShell>(find.byType(AppShell)).controller;
  expect(
    controller.state.events.length,
    expectedEvents,
    reason:
        'Inject a fresh three-event test library before the native flow suite',
  );
  expect(controller.state.photos.length, 3);
  expect(controller.selected?.id, 'test-together');
  debugPrint('SHIRI_STAGE $stage.bootstrap.ready');
  return controller;
}

Future<void> closeRealApp(
  WidgetTester tester,
  AppController? controller,
) async {
  debugPrint('SHIRI_STAGE app.cleanup.start');
  await controller?.native.stopDiscovery();
  final repositoryClosed = controller?.repository.changes.drain<void>();
  await tester.pumpWidget(const SizedBox.shrink());
  await pumpInputFrames(tester);
  await repositoryClosed;
  debugPrint('SHIRI_STAGE app.cleanup.complete');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  date_entry.main();
  testWidgets(
    'first date input and expanded picker visual preview',
    (tester) async {
      AppController? controller;
      try {
        controller = await startRealApp(tester, 'date-input-preview');
        await tab(tester, '相册');
        await tester.tap(find.byKey(const ValueKey('event-selector')));
        await pumpInputFrames(tester);
        await tester.tap(find.text('添加纪念日'));
        await pumpInputFrames(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        final input = find.byKey(const ValueKey('anniversary-start-date'));
        await tester.ensureVisible(input);
        await waitUntil(
          tester,
          () => MediaQuery.viewInsetsOf(tester.element(input)).bottom == 0,
        );
        if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
        await capture(tester, binding, '00-date-input');
        await tester.tap(input);
        await pumpInputFrames(tester);
        expect(find.byType(DatePickerDialog), findsOneWidget);
        expect(find.byType(YearPicker), findsOneWidget);
        await capture(tester, binding, '00-date-picker');
        expect(tester.takeException(), isNull);
        binding.reportData ??= <String, dynamic>{};
        binding.reportData!['dateInputPreviewComplete'] = true;
      } finally {
        await closeRealApp(tester, controller);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'real native photo flow: three tabs and selected cover',
    (tester) async {
      AppController? controller;
      try {
        controller = await startRealApp(tester, 'photos');
        final c = controller;
        expect(find.text('在一起'), findsNothing);
        expect(c.photos, hasLength(3));
        expect(find.text('${c.progress!.anniversaryNumber}周年'), findsOneWidget);
        debugPrint('SHIRI_STAGE photos.nativeWidgets');
        await c.syncWidgets();
        expect(
          c.widgetError,
          isNull,
          reason: 'Native widget snapshot must persist successfully',
        );
        debugPrint('SHIRI_STAGE photos.surface.convert');
        if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
        await tester.pumpAndSettle();
        await capture(tester, binding, '01-anniversary');
        await tab(tester, '相册');
        expect(find.text('3张'), findsOneWidget);
        expect(find.byType(Image), findsWidgets);
        await capture(tester, binding, '02-album');
        await tab(tester, '数据');
        expect(find.text('3个纪念日 · 3张照片'), findsOneWidget);
        await capture(tester, binding, '03-data');

        debugPrint('SHIRI_STAGE photos.detail.open');
        await tab(tester, '相册');
        final secondYear = find.widgetWithText(TextButton, '1张 ›').at(1);
        await tester.ensureVisible(secondYear);
        await tester.tap(secondYear);
        await tester.pumpAndSettle();
        expect(find.byType(PhotoPage), findsOneWidget);
        await tester.tap(find.byType(Image).first);
        await tester.pumpAndSettle();
        expect(find.byType(PhotoDetail), findsOneWidget);
        await tester.tap(find.byTooltip('照片操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('设为封面'));
        final chosen = c.state.photos.firstWhere(
          (photo) => photo.date.year == 2024,
        );
        await waitUntil(tester, () => c.selected?.coverPhotoId == chosen.id);
        debugPrint('SHIRI_STAGE photos.cover.saved');
        await capture(tester, binding, '04-photo-detail');
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tab(tester, '纪念日');
        expect(c.selected?.coverPhotoId, chosen.id);
        await capture(tester, binding, '05-changed-cover');
        expect(tester.takeException(), isNull);
        binding.reportData ??= <String, dynamic>{};
        binding.reportData!['photoFlowComplete'] = true;
        debugPrint('SHIRI_STAGE photos.complete');
      } finally {
        await closeRealApp(tester, controller);
      }
      // integration_test's own addTearDown now reverts the Android image surface,
      // before the next test can open an IME. No private SDK API is invoked.
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'real native date flow: create and edit before screenshot conversion',
    (tester) async {
      AppController? controller;
      try {
        controller = await startRealApp(tester, 'dates');
        final c = controller;
        debugPrint('SHIRI_STAGE dates.create.editor');
        await tab(tester, '相册');
        await tester.tap(find.byKey(const ValueKey('event-selector')));
        await pumpInputFrames(tester);
        await tester.tap(find.text('添加纪念日'));
        await pumpInputFrames(tester);
        debugPrint('SHIRI_STAGE dates.create.name');
        await tester.enterText(
          find.byKey(const ValueKey('anniversary-title')),
          '实机验收日',
        );
        await setDate(tester, DateTime(2021, 6, 18));
        await saveEditor(tester);
        await waitUntil(
          tester,
          () =>
              c.selected?.title == '实机验收日' &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(c.selected!.startDate.iso, '2021-06-18');
        expect(c.state.events.length, 4);
        expect(
          c.photos,
          isEmpty,
          reason: 'Creating an event must not insert fixed photos',
        );
        debugPrint('SHIRI_STAGE dates.create.saved');

        await tester.tap(find.byTooltip('管理纪念日'));
        await pumpInputFrames(tester);
        await tester.tap(find.text('编辑纪念日'));
        await pumpInputFrames(tester);
        debugPrint('SHIRI_STAGE dates.edit.name');
        await tester.enterText(
          find.byKey(const ValueKey('anniversary-title')),
          '实机验收日·已编辑',
        );
        await setDate(tester, DateTime(2021, 6, 19));
        await saveEditor(tester);
        await waitUntil(
          tester,
          () =>
              c.selected?.title == '实机验收日·已编辑' &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(c.selected!.startDate.iso, '2021-06-19');
        expect(c.state.photos.length, 3);
        debugPrint('SHIRI_STAGE dates.edit.saved');
        FocusManager.instance.primaryFocus?.unfocus();
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        await pumpInputFrames(tester);
        debugPrint('SHIRI_STAGE dates.surface.convert.after-ime');
        if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
        await tab(tester, '纪念日');
        await capture(tester, binding, '06-edited-anniversary');

        // Only taps and navigation after surface conversion; no text inputs.
        await tab(tester, '相册');
        await tester.tap(find.byKey(const ValueKey('event-selector')));
        await pumpInputFrames(tester);
        await tester.tap(find.text('在一起'));
        await waitUntil(tester, () => c.selected?.id == 'test-together');
        expect(tester.takeException(), isNull);
        binding.reportData ??= <String, dynamic>{};
        await c.syncWidgets();
        expect(c.widgetError, isNull);
        binding.reportData!['verification'] = {
          'completed': true,
          'platform': Platform.operatingSystem,
          'bridge': 'real-native',
          'initialEvents': 3,
          'finalEvents': c.state.events.length,
          'actualPhotos': c.state.photos.length,
          'dateEntryMode': 'calendar-year-month-day-taps',
          'createdDate': '2021-06-18',
          'editedDate': '2021-06-19',
          'coverChangedThroughPhotoDetail':
              binding.reportData!['photoFlowComplete'] == true,
          'widgetSnapshotSaved': c.widgetError == null,
        };
        debugPrint('SHIRI_STAGE dates.complete');
      } finally {
        await closeRealApp(tester, controller);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'real system photo library is filtered and automatically collected',
    (tester) async {
      AppController? controller;
      try {
        controller = await startRealApp(
          tester,
          'auto-album',
          expectedEvents: 4,
        );
        final c = controller;
        expect(
          await c.native.photoPermission(),
          'full',
          reason:
              'Grant photo access only on the isolated test simulator before this run',
        );
        await tab(tester, '相册');
        await tester.tap(find.byKey(const ValueKey('event-selector')));
        await pumpInputFrames(tester);
        await tester.scrollUntilVisible(
          find.text('添加纪念日'),
          160,
          scrollable: find
              .descendant(
                of: find.byType(BottomSheet),
                matching: find.byType(Scrollable),
              )
              .last,
        );
        await pumpInputFrames(tester);
        await tester.tap(find.text('添加纪念日'));
        await pumpInputFrames(tester);
        await tester.enterText(
          find.byKey(const ValueKey('anniversary-title')),
          '相册自动归集',
        );
        await setDate(tester, DateTime(2018, 6, 18));
        await saveEditor(tester);
        await waitUntil(
          tester,
          () =>
              c.selected?.title == '相册自动归集' &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );

        const expectedDates = {
          '2018-06-18',
          '2019-06-17',
          '2019-06-18',
          '2019-06-19',
        };
        var offset = 0;
        final pageSizes = <int>[];
        final nativeDates = <String>{};
        while (true) {
          final page = await c.native.scanPhotos(c.selected!, offset, limit: 2);
          try {
            pageSizes.add(page.items.length);
            expect(page.unavailable, 0);
            for (final photo in page.items) {
              final date = CalendarDate.fromDateTime(
                photo.capturedAt.toLocal(),
              ).iso;
              expect(expectedDates, contains(date));
              nativeDates.add(date);
            }
          } finally {
            await c.repository.discardPhotoInputs(page.items);
          }
          if (page.nextOffset == null) break;
          expect(page.nextOffset!, greaterThan(offset));
          offset = page.nextOffset!;
        }
        expect(pageSizes, [2, 2]);
        expect(nativeDates, expectedDates);
        // Saving in the album now starts collection automatically; no picker or confirmation.
        await tab(tester, '相册');
        await waitUntil(
          tester,
          () =>
              c.photos.length == 4 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(c.photos.map((photo) => photo.date.iso).toSet(), expectedDates);
        expect(c.pending, isEmpty);
        expect(c.selected!.coverPhotoId, isNotNull);
        expect(c.state.photos.length, 7);
        expect(find.text('4张'), findsOneWidget);
        await tester.tap(find.text('归集'));
        await pumpInputFrames(tester);
        await waitUntil(
          tester,
          () =>
              !c.scanningPhotos &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(c.photos, hasLength(4));
        expect(c.state.photos, hasLength(7));
        if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
        await capture(tester, binding, '07-auto-album');
        expect(tester.takeException(), isNull);
        binding.reportData ??= <String, dynamic>{};
        binding.reportData!['automaticAlbum'] = {
          'completed': true,
          'permission': c.photoAccess,
          'collected': c.photos.length,
          'pending': c.pending.length,
          'nativePages': pageSizes,
          'dates': nativeDates.toList()..sort(),
          'archivePhotos': c.state.photos.length,
          'repeatScanDeduplicated': true,
        };
      } finally {
        await closeRealApp(tester, controller);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
