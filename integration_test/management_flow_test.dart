// Run only on the owned QA emulator/simulator with the synthetic preview library.
import 'dart:io';
import 'package:anniversary/core/core.dart';
import 'package:anniversary/ui/cover_editor.dart';
import 'package:anniversary/ui/event_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'app_flow_test.dart' as flow;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native album management, covers and local calendar reminders', (
    tester,
  ) async {
    final c = await flow.startRealApp(tester, 'management');
    try {
      final tomorrow = CalendarDate.today().addDays(1);
      final annual = Anniversary(
        id: 'qa-management-annual',
        title: '拾日测试 · 每年',
        startDate: CalendarDate(2020, tomorrow.month, tomorrow.day),
        reminderEnabled: true,
      );
      final once = Anniversary(
        id: 'qa-management-once',
        title: '拾日测试 · 一次',
        startDate: tomorrow,
        repeatYearly: false,
        reminderEnabled: true,
        reminderMinute: 600,
      );
      debugPrint('SHIRI_STAGE calendar.annual.start');
      final annualStatus = await c.native.syncReminder(annual);
      debugPrint('SHIRI_STAGE calendar.annual.$annualStatus');
      expect(annualStatus, '已设置每年当天的本机日历提醒');
      final updated = annual.copyWith(
        title: '拾日测试 · 每年已更新',
        reminderMinute: 555,
      );
      expect(await c.native.syncReminder(updated), '已设置每年当天的本机日历提醒');
      expect(await c.native.syncReminder(once), '已设置一次本机日历提醒');
      expect(
        await c.native.syncReminder(once.copyWith(repeatYearly: true)),
        '已设置每年当天的本机日历提醒',
      );
      expect(await c.native.syncReminder(once), '已设置一次本机日历提醒');
      // Device-local once-per-day bookkeeping, separate from exported library.
      final off = Anniversary(
        id: 'qa-management-off',
        title: '拾日测试 · 已关闭',
        startDate: tomorrow,
        repeatYearly: false,
        reminderEnabled: true,
      );
      expect(await c.native.syncReminder(off), '已设置一次本机日历提醒');
      expect(
        await c.native.syncReminder(off.copyWith(reminderEnabled: false)),
        '当天提醒已关闭',
      );
      if (Platform.isIOS) {
        final details = <String, dynamic>{};
        for (final pair in [(annual.id, 1), (once.id, 1), (off.id, 0)]) {
          final info = await c.native.channel.invokeMapMethod<String, dynamic>('verifyCalendarFixture', {'id': pair.$1});
          expect(info?['alarms'], pair.$2);
          expect(info?['yearly'], pair.$1 == annual.id);
          expect(info?['local'], true);
          details[pair.$1] = info;
        }
        binding.reportData = {...?binding.reportData, 'eventKitInspection': details};
      }
      final marker = 'qa-seen-${DateTime.now().millisecondsSinceEpoch}';
      expect(await c.native.takeDayReminders([marker], tomorrow.iso), [marker]);
      expect(await c.native.takeDayReminders([marker], tomorrow.iso), isEmpty);
      final home = find.byKey(const ValueKey('anniversary-home'));
      expect(
        find.descendant(of: home, matching: find.byType(IconButton)),
        findsNothing,
      );
      if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
      await flow.capture(tester, binding, '01-home-no-actions');
      await flow.tab(tester, '相册');
      await flow.capture(tester, binding, '02-album-management');
      await tester.tap(find.text('多选'));
      await flow.pumpInputFrames(tester);
      await tester.tap(find.text('全选'));
      await flow.pumpInputFrames(tester);
      final count = c.photos.length;
      expect(count, greaterThan(1));
      expect(find.text('已选 $count 张'), findsOneWidget);
      await flow.capture(tester, binding, '03-multi-select');
      await tester.tap(find.text('封面组'));
      await flow.waitUntil(
        tester,
        () =>
            c.selected!.coverMode == CoverMode.slideshow &&
            find.text('多选').evaluate().isNotEmpty,
      );
      expect(c.selected!.coverPhotoIds.length, count);
      await tester.tap(find.byType(BackButton));
      await flow.pumpInputFrames(tester);
      await tester.tap(find.byTooltip('管理纪念日'));
      await flow.pumpInputFrames(tester);
      await tester.tap(find.text('封面展示'));
      await flow.pumpInputFrames(tester);
      expect(find.byType(CoverEditor), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<CoverMode>));
      await flow.pumpInputFrames(tester);
      await tester.tap(find.text('每天定时换图').last);
      await flow.pumpInputFrames(tester);
      await flow.capture(tester, binding, '04-cover-settings');
      await tester.tap(find.text('保存'));
      await flow.waitUntil(
        tester,
        () => find.byType(CoverEditor).evaluate().isEmpty,
      );
      expect(c.selected!.coverMode, CoverMode.daily);
      // Reopening preserves the scheduled selection and selected photo group.
      await tester.tap(find.byTooltip('管理纪念日'));
      await flow.pumpInputFrames(tester);
      await tester.tap(find.text('编辑纪念日'));
      await flow.pumpInputFrames(tester);
      FocusManager.instance.primaryFocus?.unfocus();
      await flow.pumpInputFrames(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('anniversary-repeat')),
      );
      await flow.pumpInputFrames(tester);
      await flow.capture(tester, binding, '05-repeat-settings');
      Navigator.of(tester.element(find.byType(EventEditor))).pop();
      await flow.pumpInputFrames(tester);
      // Real native snapshot also receives the recurrence setting.
      await c.syncWidgets();
      expect(c.widgetError, isNull);
      binding.reportData = {
        ...?binding.reportData,
        'management': {
          'completed': true,
          'platform': Platform.operatingSystem,
          'selectedCount': count,
          'coverMode': c.selected!.coverMode.name,
          'annualCalendar': annualStatus,
          'onceCalendar': true,
          'calendarUpsert': true,
          'dailyReminderDedup': true,
          'widgetSnapshot': true,
        },
      };
      expect(tester.takeException(), isNull);
    } finally {
      await flow.closeRealApp(tester, c);
    }
  });
}
