import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/app_flow_test.dart' as native_flow;

void main() {
  testWidgets(
    'native-flow calendar gesture helper selects year month and day through UI',
    (tester) async {
      var selected = DateTime(2026, 11, 13);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => Column(
                children: [
                  Text(
                    '${selected.year.toString().padLeft(4, '0')}.${selected.month.toString().padLeft(2, '0')}.${selected.day.toString().padLeft(2, '0')}',
                  ),
                  TextButton(
                    onPressed: () async {
                      final value = await showDatePicker(
                        context: context,
                        initialDate: selected,
                        firstDate: DateTime(1),
                        lastDate: DateTime(9999, 12, 31),
                      );
                      if (value != null) update(() => selected = value);
                    },
                    child: const Text('首次日期'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await native_flow.setDate(tester, DateTime(2021, 6, 18));
      expect(selected, DateTime(2021, 6, 18));
      await native_flow.setDate(tester, DateTime(2021, 6, 19));
      expect(selected, DateTime(2021, 6, 19));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
