import 'dart:io';
import 'package:anniversary/core/core.dart';
import 'package:anniversary/platform/native_platform.dart';
import 'package:anniversary/ui/app_controller.dart';
import 'package:anniversary/ui/app_shell.dart';
import 'package:anniversary/ui/photo_page.dart';
import 'package:anniversary/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('com.shiri.anniversary/platform');

class _Harness {
  _Harness(this.directory, this.repository, this.controller);
  final Directory directory;
  final LibraryRepository repository;
  final AppController controller;
  List<Map<String, dynamic>>? picked;
  List<Map<String, dynamic>> scanned = [];
  String permission = 'full';
  String requestedPermission = 'full';
  String? importPath;
  final seenReminders = <String>{};
  final List<MethodCall> calls = [];
  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'pickPhotos':
        return picked;
      case 'photoPermission':
        return permission;
      case 'requestPhotoPermission':
        return permission = requestedPermission;
      case 'scanPhotos':
        return {'items': scanned, 'nextOffset': null, 'unavailable': 0};
      case 'importFile':
        return importPath;
      case 'syncReminder':
        return '已设置本机日历提醒';
      case 'takeDayReminders':
        final ids = (call.arguments['ids'] as List).cast<String>();
        return ids
            .where((id) => seenReminders.add('$id:${call.arguments['date']}'))
            .toList();
      case 'updateWidgets':
      case 'stopDiscovery':
      case 'openSettings':
        return null;
      case 'requestPinWidget':
        return false;
      default:
        throw MissingPluginException(
          'Unexpected test platform call: ${call.method}',
        );
    }
  }

  Future<Map<String, dynamic>> photo(
    String fixture, {
    DateTime? captured,
  }) async {
    final id = newId();
    final source = File('test/fixtures/$fixture.png');
    final original = await source.copy(
      '${repository.directory.path}/imports/$id.png',
    );
    final thumbnail = await source.copy(
      '${repository.directory.path}/imports/$id-thumb.jpg',
    );
    return {
      'sourceId': id,
      'originalPath': original.path,
      'thumbnailPath': thumbnail.path,
      'capturedAt': (captured ?? DateTime(2025, 11, 20, 12)).toIso8601String(),
      'originalName': '$fixture.png',
      'mimeType': 'image/png',
    };
  }

  Future<void> addEvent({String title = '我们的纪念日', CalendarDate? date}) =>
      repository.saveEvent(
        Anniversary(
          id: 'our-day',
          title: title,
          startDate: date ?? CalendarDate(2022, 11, 20),
        ),
      );
}

Future<void> _withApp(
  WidgetTester tester,
  Future<void> Function(_Harness) body, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  late _Harness h;
  await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('shiri-widget-');
    final repo = await LibraryRepository.open(
      Directory('${dir.path}/documents'),
    );
    final temp = await Directory('${dir.path}/temporary').create();
    final controller = AppController(
      repository: repo,
      native: NativePlatform(channel: _channel),
      temporary: temp,
      clock: () => CalendarDate(2026, 11, 13),
    );
    h = _Harness(dir, repo, controller);
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, h.handle);
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: ShiriTheme.light,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: AppShell(controller: h.controller),
      ),
    );
    await tester.pumpAndSettle();
    await body(h);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    var closed = false;
    final closing = h.controller.close().whenComplete(() => closed = true);
    await _until(tester, () => closed, settle: false);
    await closing;
    await tester.runAsync(() async {
      await h.directory.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

// File IO uses real time while animations use the widget tester's fake clock.
Future<void> _until(
  WidgetTester tester,
  bool Function() done, {
  bool settle = true,
}) async {
  // Allow real file hashing/copying to finish under concurrent native builds.
  // The business condition must still become true; no fixed success delay.
  var stable = 0;
  for (var i = 0; i < 1200 && stable < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 25));
    if (done() &&
        (!settle || find.byType(LinearProgressIndicator).evaluate().isEmpty)) {
      stable++;
    } else {
      stable = 0;
    }
  }
  expect(done(), true, reason: 'Asynchronous UI action did not complete');
  if (settle) await tester.pumpAndSettle();
}

Future<void> _tab(WidgetTester tester, String name) async {
  await tester.tap(
    find.descendant(
      of: find.byType(BottomNavigationBar),
      matching: find.byTooltip(name),
    ),
  );
  await tester.pump();
  await tester.pump();
  await _until(
    tester,
    () =>
        !tester
            .widget<AppShell>(find.byType(AppShell))
            .controller
            .scanningPhotos &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty,
  );
}

Future<void> _pickPhoto(WidgetTester tester, _Harness h) async {
  await _tab(tester, '相册');
  await tester.tap(find.byTooltip('手动添加照片'));
  await _until(
    tester,
    () =>
        h.repository.state.photos.isNotEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty,
  );
}

Future<void> _createAnniversary(
  WidgetTester tester,
  _Harness h,
  String title,
) async {
  await _tab(tester, '相册');
  if (h.repository.state.events.isNotEmpty) {
    await tester.tap(find.byTooltip('管理纪念日'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('添加纪念日'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('anniversary-title')),
    title,
  );
  FocusManager.instance.primaryFocus?.unfocus();
  final reminder = find.byType(SwitchListTile);
  await tester.ensureVisible(reminder);
  await tester.pumpAndSettle();
  if (tester.widget<SwitchListTile>(reminder).value) await tester.tap(reminder);
  await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '保存'));
  await _until(
    tester,
    () =>
        h.controller.selected?.title == title &&
        !h.controller.scanningPhotos &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty,
  );
}

void main() {
  testWidgets(
    'each new anniversary scans once; edit, resume and reopening do not rescan',
    (tester) async {
      await _withApp(tester, (h) async {
        await tester.runAsync(() async {
          h.scanned = [
            await h.photo('cover', captured: DateTime(2026, 11, 13)),
          ];
        });
        await _createAnniversary(tester, h, '新纪念日');
        expect(h.controller.photos, hasLength(1));
        expect(h.calls.where((c) => c.method == 'scanPhotos'), hasLength(1));
        await _tab(tester, '纪念日');
        await _tab(tester, '相册');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('管理纪念日'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑纪念日'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('anniversary-title')),
          '修改过的纪念日',
        );
        await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await _until(tester, () => h.controller.selected?.title == '修改过的纪念日');
        await tester.pumpWidget(
          MaterialApp(
            theme: ShiriTheme.light,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: AppShell(key: UniqueKey(), controller: h.controller),
          ),
        );
        await tester.pumpAndSettle();
        await _tab(tester, '相册');
        expect(h.calls.where((c) => c.method == 'scanPhotos'), hasLength(1));
        await tester.runAsync(() async {
          h.scanned = [await h.photo('cake', captured: DateTime(2026, 11, 13))];
        });
        await _createAnniversary(tester, h, '第二个纪念日');
        expect(h.calls.where((c) => c.method == 'scanPhotos'), hasLength(2));
        expect(h.controller.photos.single.originalName, 'cake.png');
      });
    },
  );

  testWidgets(
    'denied initial attempt is not retried after permission change; manual collection works',
    (tester) async {
      await _withApp(tester, (h) async {
        h.permission = 'notDetermined';
        h.requestedPermission = 'denied';
        await _createAnniversary(tester, h, '仅尝试一次');
        expect(
          h.calls.where((c) => c.method == 'requestPhotoPermission'),
          hasLength(1),
        );
        expect(h.calls.where((c) => c.method == 'scanPhotos'), isEmpty);
        h.permission = 'full';
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _tab(tester, '纪念日');
        await _tab(tester, '相册');
        expect(h.calls.where((c) => c.method == 'scanPhotos'), isEmpty);
        await tester.tap(find.text('归集'));
        await _until(
          tester,
          () => h.calls.any((c) => c.method == 'scanPhotos'),
        );
        expect(h.calls.where((c) => c.method == 'scanPhotos'), hasLength(1));
      });
    },
  );

  testWidgets(
    'album uses bundled Source Han Sans and muted colors with readable contrast',
    (tester) async {
      await _withApp(tester, (h) async {
        await tester.runAsync(() => h.addEvent());
        await _tab(tester, '相册');
        final theme = Theme.of(
          tester.element(find.byKey(const ValueKey('event-selector'))),
        );
        expect(theme.textTheme.bodyMedium?.fontFamily, ShiriTheme.fontFamily);
        expect(theme.colorScheme.primary, ShiriTheme.albumAccent);
        for (final color in [
          ShiriTheme.albumInk,
          ShiriTheme.albumMuted,
          ShiriTheme.albumAccent,
        ]) {
          expect(
            1.05 / (color.computeLuminance() + .05),
            greaterThanOrEqualTo(4.5),
          );
        }
      });
    },
  );

  testWidgets('today reminder appears once and does not reappear on resume', (
    tester,
  ) async {
    await _withApp(tester, (h) async {
      await tester.runAsync(
        () => h.repository.saveEvent(
          Anniversary(
            id: 'today',
            title: '今天的日子',
            startDate: h.controller.clock(),
            reminderEnabled: true,
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _until(tester, () => find.text('今天是纪念日').evaluate().isNotEmpty);
      expect(find.text('今天的日子'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _until(
        tester,
        () => h.calls.where((c) => c.method == 'takeDayReminders').length >= 2,
      );
      expect(find.text('今天是纪念日'), findsNothing);
    });
  });

  testWidgets(
    'confirmed photos support multi-select cover and explicit batch removal',
    (tester) async {
      await _withApp(tester, (h) async {
        await tester.runAsync(() async {
          await h.addEvent();
          final a = await h.photo('cover');
          final b = await h.photo('cake');
          await h.repository.ingestPhotos('our-day', [
            PhotoInput.fromMap(a),
            PhotoInput.fromMap(b),
          ]);
        });
        await _tab(tester, '相册');
        await tester.tap(find.text('多选'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全选'));
        await tester.pumpAndSettle();
        expect(find.text('已选 2 张'), findsOneWidget);
        await tester.tap(find.text('封面组'));
        await _until(
          tester,
          () =>
              h.controller.selected!.coverPhotoIds.length == 2 &&
              find.text('多选').evaluate().isNotEmpty,
        );
        expect(h.controller.selected!.coverMode, CoverMode.slideshow);
        await tester.tap(find.text('多选'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全选'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移出'));
        await tester.pumpAndSettle();
        expect(find.text('移出 2 张照片？'), findsOneWidget);
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(h.controller.photos.length, 2);
        await tester.tap(find.text('移出'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('执行移出'));
        await _until(tester, () => h.controller.photos.isEmpty);
        expect(h.controller.state.photos.length, 2);
        expect(h.controller.selected!.coverPhotoIds, isEmpty);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets('home has no management actions; album owns event management', (
    tester,
  ) async {
    await _withApp(tester, (h) async {
      await tester.runAsync(() async {
        await h.addEvent();
        await h.repository.saveEvent(
          Anniversary(
            id: 'other',
            title: '另一个纪念日',
            startDate: CalendarDate(2020, 5, 6),
          ),
        );
      });
      await tester.pumpAndSettle();
      final home = find.byKey(const ValueKey('anniversary-home'));
      final labels = tester
          .widgetList<Text>(
            find.descendant(of: home, matching: find.byType(Text)),
          )
          .map((text) => text.data ?? text.textSpan!.toPlainText())
          .toList();
      expect(labels, ['7', '天后', '4周年', '已经走过 1,454 天']);
      final navigation = tester.widget<BottomNavigationBar>(
        find.byType(BottomNavigationBar),
      );
      expect(navigation.showSelectedLabels, false);
      expect(navigation.showUnselectedLabels, false);

      expect(
        find.descendant(of: home, matching: find.byType(IconButton)),
        findsNothing,
      );
      expect(
        find.descendant(of: home, matching: find.byType(TextButton)),
        findsNothing,
      );
      await _tab(tester, '相册');
      await tester.tap(find.text('我们的纪念日'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('另一个纪念日'));
      await _until(
        tester,
        () =>
            h.controller.selected?.id == 'other' &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(find.text('另一个纪念日'), findsOneWidget);
      await tester.tap(find.byTooltip('管理纪念日'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑纪念日'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('anniversary-title')))
            .controller!
            .text,
        '另一个纪念日',
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'warm widget deep link leaves old photo routes only for a valid event',
    (tester) async {
      await _withApp(tester, (h) async {
        await tester.runAsync(() async {
          await h.addEvent();
          await h.repository.saveEvent(
            Anniversary(
              id: 'other-day',
              title: '另一个纪念日',
              startDate: CalendarDate(2020, 5, 6),
            ),
          );
          h.picked = [await h.photo('cover')];
        });
        await tester.pumpAndSettle();
        await _pickPhoto(tester, h);
        await tester.tap(find.widgetWithText(TextButton, '1张 ›'));
        await tester.pumpAndSettle();
        expect(find.byType(PhotoPage), findsOneWidget);
        await tester.tap(find.byType(Image).first);
        await tester.pumpAndSettle();
        expect(find.byType(PhotoDetail), findsOneWidget);
        expect(h.controller.selected!.id, 'our-day');

        Future<void> sendNativeDeepLink(String link) async {
          var replied = false;
          final delivery = TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .handlePlatformMessage(
                _channel.name,
                _channel.codec.encodeMethodCall(MethodCall('onDeepLink', link)),
                (reply) {
                  expectSync(reply, isNotNull);
                  expectSync(_channel.codec.decodeEnvelope(reply!), isNull);
                  replied = true;
                },
              );
          await _until(tester, () => replied);
          await delivery;
        }

        for (final invalid in [
          'shiri://anniversary/missing-day',
          'https://anniversary/other-day',
        ]) {
          await sendNativeDeepLink(invalid);
          expect(h.controller.selected!.id, 'our-day');
          expect(
            find.byType(PhotoDetail),
            findsOneWidget,
            reason:
                'Invalid native links must preserve the current photo route',
          );
          expect(find.byType(PhotoPage, skipOffstage: false), findsOneWidget);
        }

        await sendNativeDeepLink('shiri://anniversary/other-day');
        await _until(
          tester,
          () =>
              h.controller.selected?.id == 'other-day' &&
              find.byType(PhotoDetail, skipOffstage: false).evaluate().isEmpty,
        );
        expect(find.byType(PhotoPage, skipOffstage: false), findsNothing);
        expect(find.byType(PhotoDetail, skipOffstage: false), findsNothing);
        expect(find.text('另一个纪念日'), findsNothing);
        expect(
          find.text('${h.controller.progress!.anniversaryNumber}周年'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
              .currentIndex,
          0,
        );
        expect(
          h.repository.state.photos,
          hasLength(1),
          reason: 'Navigation must preserve archived photos',
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets('fresh install has no example anniversaries or bundled photos', (
    tester,
  ) async {
    await _withApp(tester, (h) async {
      expect(h.repository.state.events, isEmpty);
      expect(h.repository.state.photos, isEmpty);
      expect(find.byType(Image), findsNothing);
      expect(find.text('在一起'), findsNothing);
      expect(find.byTooltip('添加纪念日'), findsNothing);
      expect(find.text('在相册中添加纪念日'), findsOneWidget);
      expect(find.text('从一个重要的日子开始'), findsNothing);
      await _tab(tester, '数据');
      expect(find.text('0个纪念日 · 0张照片'), findsOneWidget);
      expect(find.text('0 B'), findsOneWidget);
      expect(
        h.calls.where(
          (c) => c.method == 'pickPhotos' || c.method == 'scanPhotos',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  });
  testWidgets('user chosen event date drives homepage day counts', (
    tester,
  ) async {
    await _withApp(tester, (h) async {
      await _tab(tester, '相册');
      await tester.tap(find.text('添加纪念日'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('anniversary-title')),
        '我们的纪念日',
      );
      await tester.tap(find.byKey(const ValueKey('anniversary-start-date')));
      await tester.pumpAndSettle();
      final picker = find.byType(DatePickerDialog);
      final labels = MaterialLocalizations.of(tester.element(picker));
      await tester.tap(find.byTooltip(labels.inputDateModeButtonLabel));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: picker, matching: find.byType(TextField)),
        '2022.11.20',
      );
      await tester.tap(
        find.descendant(of: picker, matching: find.text(labels.okButtonLabel)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await _until(
        tester,
        () =>
            h.repository.state.events.length == 1 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(h.repository.state.events.single.startDate.iso, '2022-11-20');
      await tester.runAsync(() async {
        final reopened = await LibraryRepository.open(h.repository.directory);
        try {
          expect(reopened.state.events.single.startDate.iso, '2022-11-20');
        } finally {
          await reopened.close();
        }
      });
      await _tab(tester, '纪念日');
      expect(find.text('我们的纪念日'), findsNothing);
      expect(find.text('4周年'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('已经走过 1,454 天', findRichText: true), findsOneWidget);
      expect(find.text('始于2022.11.20'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
  testWidgets(
    'native picker imports actual files and all tabs show repository counts',
    (tester) async {
      await _withApp(tester, (h) async {
        await tester.runAsync(() async {
          await h.addEvent();
          h.picked = [await h.photo('cover')];
        });
        await tester.pumpAndSettle();
        await _pickPhoto(tester, h);
        expect(h.calls.where((c) => c.method == 'pickPhotos'), hasLength(1));
        expect(h.repository.state.photosFor('our-day'), hasLength(1));
        expect(find.text('1张'), findsOneWidget);
        expect(find.text('2025'), findsOneWidget);
        final photo = h.repository.state.photos.single;
        final files = tester.widgetList<Image>(find.byType(Image)).map((image) {
          final p = image.image is ResizeImage
              ? (image.image as ResizeImage).imageProvider
              : image.image;
          return p is FileImage ? p.file.path : null;
        });
        expect(files, contains(h.repository.thumbnailFile(photo).path));
        await tester.runAsync(() async {
          expect(
            await fileSha256(h.repository.originalFile(photo)),
            await fileSha256(File('test/fixtures/cover.png')),
          );
          expect(
            await Directory(
              '${h.repository.directory.path}/imports',
            ).list().toList(),
            isEmpty,
          );
        });
        await _tab(tester, '数据');
        expect(find.text('1个纪念日 · 1张照片'), findsOneWidget);
        expect(
          find.text(byteLabel(h.repository.state.mediaBytes)),
          findsOneWidget,
        );
        await _tab(tester, '纪念日');
        expect(find.text('共 1 张'), findsNothing);
        expect(find.byType(Image), findsOneWidget);
        expect(h.repository.state.events.single.coverPhotoId, photo.id);
        expect(tester.takeException(), isNull);
      });
    },
  );
  testWidgets(
    'entering album is read-only; explicit collection filters the range',
    (tester) async {
      await _withApp(tester, (h) async {
        await tester.runAsync(() async {
          await h.addEvent();
          h.scanned = [
            await h.photo('cover', captured: DateTime(2022, 11, 20)),
            await h.photo('cake', captured: DateTime(2023, 11, 19)),
            await h.photo('coffee', captured: DateTime(2024, 11, 21)),
            await h.photo('cover', captured: DateTime(2022, 11, 19)),
            await h.photo('cake', captured: DateTime(2024, 11, 22)),
          ];
        });
        await tester.pumpAndSettle();
        await _tab(tester, '相册');
        expect(h.calls.where((call) => call.method == 'scanPhotos'), isEmpty);
        expect(h.controller.photos, isEmpty);
        await tester.tap(find.text('归集'));
        await _until(tester, () => h.controller.photos.length == 3);
        expect(h.controller.photos, hasLength(3));
        expect(h.controller.pending, isEmpty);
        expect(h.controller.selected!.coverPhotoId, isNotNull);
        expect(find.text('3张'), findsOneWidget);
        expect(find.text('待确认0张 ›'), findsNothing);
        expect(h.calls.where((call) => call.method == 'pickPhotos'), isEmpty);
        expect(
          h.calls.where((call) => call.method == 'scanPhotos'),
          hasLength(1),
        );
        await _tab(tester, '纪念日');
        await _tab(tester, '相册');
        expect(
          h.calls.where((call) => call.method == 'scanPhotos'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'limited and denied photo access are visible with a settings action',
    (tester) async {
      await _withApp(tester, (h) async {
        await tester.runAsync(() async {
          await h.addEvent();
        });
        h.permission = 'limited';
        await tester.pumpAndSettle();
        await _tab(tester, '相册');
        expect(find.text('仅已授权照片'), findsOneWidget);
        await tester.tap(find.text('相册权限'));
        await _until(
          tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(
          h.calls.where((call) => call.method == 'openSettings'),
          hasLength(1),
        );
        h.permission = 'denied';
        await tester.tap(find.text('归集'));
        await _until(
          tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(find.text('未允许读取相册'), findsOneWidget);
        expect(h.calls.where((call) => call.method == 'scanPhotos'), isEmpty);
      });
    },
  );

  testWidgets(
    'import preview preserves existing data and cancel cleans only staging',
    (tester) async {
      await _withApp(tester, (h) async {
        await tester.runAsync(() async {
          await h.addEvent();
          final source = await LibraryRepository.open(
            Directory('${h.directory.path}/source'),
          );
          try {
            await source.saveEvent(
              Anniversary(
                id: 'our-day',
                title: '对方的名称',
                startDate: CalendarDate(2020, 1, 1),
              ),
            );
            await source.saveEvent(
              Anniversary(
                id: 'new-day',
                title: '另一个日子',
                startDate: CalendarDate(2021, 2, 3),
              ),
            );
            h.importPath = (await ArchiveService(source).exportTo(
              File('${h.controller.temporary.path}/incoming.shiri'),
            )).path;
          } finally {
            await source.close();
          }
        });
        await tester.pumpAndSettle();
        await _tab(tester, '数据');
        await tester.tap(find.text('导入备份'));
        await _until(
          tester,
          () => find.text('导入预览').evaluate().isNotEmpty,
          settle: false,
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('冲突保留本机内容'), findsOneWidget);
        expect(h.repository.state.events, hasLength(1));
        expect(h.repository.state.events.single.title, '我们的纪念日');
        await tester.tap(find.text('取消'));
        await _until(
          tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(h.repository.state.events, hasLength(1));
        expect(h.repository.state.events.single.startDate.iso, '2022-11-20');
        await tester.runAsync(() async {
          expect(await File(h.importPath!).exists(), false);
          expect(
            await Directory(
              '${h.repository.directory.path}/staging',
            ).list().toList(),
            isEmpty,
          );
          final source = await LibraryRepository.open(
            Directory('${h.directory.path}/source'),
          );
          try {
            h.importPath = (await ArchiveService(source).exportTo(
              File('${h.controller.temporary.path}/incoming-confirmed.shiri'),
            )).path;
          } finally {
            await source.close();
          }
        });
        await tester.tap(find.text('导入备份'));
        await _until(
          tester,
          () => find.text('导入预览').evaluate().isNotEmpty,
          settle: false,
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('合并导入'));
        await _until(
          tester,
          () =>
              h.repository.state.events.length == 2 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(
          h.repository.state.events.firstWhere((e) => e.id == 'our-day').title,
          '我们的纪念日',
        );
        expect(
          h.repository.state.events
              .firstWhere((e) => e.id == 'our-day')
              .startDate
              .iso,
          '2022-11-20',
        );
        expect(
          h.repository.state.events.firstWhere((e) => e.id == 'new-day').title,
          '另一个日子',
        );
        expect(tester.takeException(), isNull);
      });
    },
  );
  testWidgets(
    '320px phone has no overflow on all tabs with and without cover',
    (tester) async {
      await _withApp(tester, (h) async {
        await tester.runAsync(() async {
          await h.addEvent();
          h.picked = [await h.photo('coffee')];
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _pickPhoto(tester, h);
        expect(tester.takeException(), isNull);
        await _tab(tester, '数据');
        expect(tester.takeException(), isNull);
        await _tab(tester, '纪念日');
        expect(tester.takeException(), isNull);
      }, size: const Size(320, 640));
    },
  );
  testWidgets('long future countdown stays readable on a narrow phone', (
    tester,
  ) async {
    await _withApp(tester, (h) async {
      await tester.runAsync(() => h.addEvent(date: CalendarDate(2030, 1, 1)));
      await tester.pumpAndSettle();
      final days = anniversaryProgress(
        CalendarDate(2030, 1, 1),
        today: CalendarDate(2026, 11, 13),
      ).countdownDays;
      expect(find.text('$days'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, size: const Size(320, 640));
  });

  testWidgets('large text remains usable across all tabs', (tester) async {
    await _withApp(
      tester,
      (h) async {
        await tester.runAsync(() async {
          await h.addEvent();
          h.picked = [await h.photo('cake')];
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _pickPhoto(tester, h);
        expect(tester.takeException(), isNull);
        await _tab(tester, '数据');
        expect(tester.takeException(), isNull);
      },
      size: const Size(390, 844),
      textScale: 1.5,
    );
  });
}
