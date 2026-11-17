import 'package:anniversary/core/core.dart';
import 'package:anniversary/ui/event_editor.dart';
import 'package:anniversary/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

// Real Android IME animations can keep scheduling frames. Always assert the
// resulting dialog/date state instead of waiting for all frames to stop.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _openEditor(
  WidgetTester tester,
  ValueChanged<Anniversary?> onSaved, {
  Anniversary? event,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ShiriTheme.light,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                onSaved(
                  await showModalBottomSheet<Anniversary>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => EventEditor(
                      event: event,
                      today: CalendarDate(2026, 11, 16),
                    ),
                  ),
                );
              },
              child: const Text('创建'),
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  await tester.tap(find.text('创建'));
  await _frames(tester);
  await tester.enterText(
    find.byKey(const ValueKey('anniversary-title')),
    '在一起',
  );
  await _frames(tester);
}

Future<MaterialLocalizations> _openInput(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('anniversary-start-date')));
  await _frames(tester);
  final dialog = find.byType(DatePickerDialog);
  expect(
    find.byType(YearPicker),
    findsOneWidget,
    reason: 'Historic years must be immediately selectable',
  );
  final labels = MaterialLocalizations.of(tester.element(dialog));
  await tester.tap(find.byTooltip(labels.inputDateModeButtonLabel));
  await _frames(tester);
  return labels;
}

Future<void> _enterDate(WidgetTester tester, String input) async {
  final field = find.descendant(
    of: find.byType(DatePickerDialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(field, input);
  await _frames(tester);
  expect(
    tester.widget<TextField>(field).controller!.text,
    input,
    reason: 'The real date field must receive the text before confirmation',
  );
}

Future<void> _confirm(WidgetTester tester, MaterialLocalizations labels) async {
  await tester.tap(
    find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.text(labels.okButtonLabel),
    ),
  );
  await _frames(tester);
}

Future<void> _save(WidgetTester tester) async {
  await tester.ensureVisible(find.text('保存'));
  await _frames(tester);
  await tester.tap(find.text('保存'));
  await _frames(tester);
  expect(find.byType(EventEditor), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('new event defaults to annual reminder and can switch to once', (
    tester,
  ) async {
    Anniversary? saved;
    await _openEditor(tester, (value) => saved = value);
    final repeat = find.byKey(const ValueKey('anniversary-repeat'));
    await tester.ensureVisible(repeat);
    await _frames(tester);
    await tester.tap(repeat);
    await _frames(tester);
    await tester.tap(find.text('不重复').last);
    await _frames(tester);
    await _save(tester);
    expect(saved?.repeatYearly, false);
    expect(saved?.reminderEnabled, true);
    expect(saved?.reminderMinute, 540);
  });

  testWidgets(
    'outlined first date input and calendar icon both open the picker',
    (tester) async {
      await _openEditor(tester, (_) {});
      final input = find.byKey(const ValueKey('anniversary-start-date'));
      final field = tester.widget<TextField>(input);
      expect(field.controller!.text, '2026.11.16');
      expect(field.decoration!.labelText, '首次日期');
      final decoration = tester.widget<InputDecorator>(
        find.descendant(of: input, matching: find.byType(InputDecorator)),
      );
      expect(decoration.decoration.border, isA<OutlineInputBorder>());
      for (final target in [input, find.byTooltip('选择首次日期')]) {
        await tester.tap(target);
        await _frames(tester);
        final dialog = find.byType(DatePickerDialog);
        expect(dialog, findsOneWidget);
        expect(find.byType(YearPicker), findsOneWidget);
        final labels = MaterialLocalizations.of(tester.element(dialog));
        await tester.tap(
          find.descendant(
            of: dialog,
            matching: find.text(labels.cancelButtonLabel),
          ),
        );
        await _frames(tester);
        expect(dialog, findsNothing);
        expect(tester.widget<TextField>(input).controller!.text, '2026.11.16');
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final input in ['2021/06/18', '2021.06.18', '2021-06-18', '20210618']) {
    testWidgets('past date input $input returns the entered date', (
      tester,
    ) async {
      Anniversary? saved;
      await _openEditor(tester, (value) => saved = value);
      final labels = await _openInput(tester);
      await _enterDate(tester, input);
      await _confirm(tester, labels);
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(find.text('2021.06.18'), findsOneWidget);
      await _save(tester);
      expect(saved?.startDate.iso, '2021-06-18');
    });
  }

  testWidgets(
    'invalid dates stay in the dialog and a valid leap day recovers',
    (tester) async {
      Anniversary? saved;
      await _openEditor(tester, (value) => saved = value);
      final labels = await _openInput(tester);
      for (final invalid in [
        '2021.02.29',
        '2022-02-30',
        '19000229',
        '0000.01.01',
        '',
      ]) {
        await _enterDate(tester, invalid);
        await _confirm(tester, labels);
        expect(find.byType(DatePickerDialog), findsOneWidget);
        expect(find.text('请输入有效日期，如 2022.11.20'), findsOneWidget);
        expect(saved, isNull);
      }
      await _enterDate(tester, '20000229');
      await _confirm(tester, labels);
      await _save(tester);
      expect(saved?.startDate.iso, '2000-02-29');
    },
  );

  testWidgets('cancel date input preserves an existing anniversary and cover', (
    tester,
  ) async {
    Anniversary? saved;
    await _openEditor(
      tester,
      (value) => saved = value,
      event: Anniversary(
        id: 'existing',
        title: '在一起',
        startDate: CalendarDate(1998, 5, 20),
        coverPhotoId: 'a' * 64,
      ),
    );
    final labels = await _openInput(tester);
    await _enterDate(tester, '2000.02.29');
    await tester.tap(
      find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text(labels.cancelButtonLabel),
      ),
    );
    await _frames(tester);
    expect(find.text('1998.05.20'), findsOneWidget);
    await _save(tester);
    expect(saved?.startDate.iso, '1998-05-20');
    expect(saved?.id, 'existing');
    expect(saved?.coverPhotoId, 'a' * 64);
  });

  testWidgets('future first dates remain supported', (tester) async {
    Anniversary? saved;
    await _openEditor(tester, (value) => saved = value);
    final labels = await _openInput(tester);
    await _enterDate(tester, '2030.01.01');
    await _confirm(tester, labels);
    await _save(tester);
    expect(saved?.startDate.iso, '2030-01-01');
  });

  testWidgets(
    'past year is selectable immediately and calendar selection saves',
    (tester) async {
      Anniversary? saved;
      await _openEditor(tester, (value) => saved = value);
      await tester.tap(find.byKey(const ValueKey('anniversary-start-date')));
      await _frames(tester);
      final years = find.byType(YearPicker);
      expect(years, findsOneWidget);
      final year = find.descendant(
        of: years,
        matching: find.byKey(const ValueKey<int>(2022)),
      );
      await tester.scrollUntilVisible(
        year,
        -150,
        scrollable: find
            .descendant(of: years, matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(year);
      await _frames(tester);
      expect(years, findsNothing);
      final day = find.byKey(ValueKey<DateTime>(DateTime(2022, 11, 20)));
      await tester.tap(day);
      await _frames(tester);
      final labels = MaterialLocalizations.of(
        tester.element(find.byType(DatePickerDialog)),
      );
      await _confirm(tester, labels);
      expect(find.text('2022.11.20'), findsOneWidget);
      await _save(tester);
      expect(saved?.startDate.iso, '2022-11-20');
    },
  );
}
