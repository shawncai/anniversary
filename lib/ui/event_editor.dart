import 'package:flutter/material.dart';

import '../core/calendar.dart';
import '../core/models.dart';
import 'theme.dart';

class EventEditor extends StatefulWidget {
  const EventEditor({super.key, this.event, required this.today});
  final Anniversary? event;
  final CalendarDate today;
  @override
  State<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<EventEditor> {
  late final TextEditingController _title;
  late final TextEditingController _dateText;
  late CalendarDate _date;
  late int _window;
  late bool _repeat;
  late bool _reminder;
  late TimeOfDay _reminderTime;
  String? _error;
  bool _pickingDate = false;
  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.event?.title ?? '');
    _date = widget.event?.startDate ?? widget.today;
    _dateText = TextEditingController(text: dateLabel(_date.iso));
    _window = widget.event?.windowDays ?? 1;
    _repeat = widget.event?.repeatYearly ?? true;
    _reminder = widget.event?.reminderEnabled ?? true;
    final minute = widget.event?.reminderMinute ?? 540;
    _reminderTime = TimeOfDay(hour: minute ~/ 60, minute: minute % 60);
  }

  @override
  void dispose() {
    _title.dispose();
    _dateText.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    if (_pickingDate) return;
    _pickingDate = true;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final picked = await showDatePicker(
        context: context,
        initialDate: DateTime(_date.year, _date.month, _date.day),
        currentDate: DateTime(
          widget.today.year,
          widget.today.month,
          widget.today.day,
        ),
        firstDate: DateTime(1),
        lastDate: DateTime(9999, 12, 31),
        initialDatePickerMode: DatePickerMode.year,
        helpText: '选择首次日期',
        fieldLabelText: '首次日期',
        errorFormatText: '请输入有效日期，如 2022.11.20',
        calendarDelegate: const _AnniversaryCalendarDelegate(),
      );
      if (picked != null && mounted) {
        setState(() {
          _date = CalendarDate.fromDateTime(picked);
          _dateText.text = dateLabel(_date.iso);
        });
      }
    } finally {
      _pickingDate = false;
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        24,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.event == null ? '添加纪念日' : '编辑纪念日',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            TextField(
              key: const ValueKey('anniversary-title'),
              controller: _title,
              autofocus: true,
              maxLength: 80,
              decoration: InputDecoration(labelText: '名称', errorText: _error),
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('anniversary-start-date'),
              controller: _dateText,
              readOnly: true,
              showCursor: false,
              enableInteractiveSelection: false,
              decoration: InputDecoration(
                labelText: '首次日期',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                suffixIcon: IconButton(
                  tooltip: '选择首次日期',
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_month_outlined),
                ),
              ),
              onTap: _pickDate,
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<int>(
              value: _window,
              decoration: const InputDecoration(labelText: '照片归集日期范围'),
              items: ({0, 1, 3, 7, 14, 31, _window}.toList()..sort())
                  .map(
                    (n) => DropdownMenuItem(
                      value: n,
                      child: Text(n == 0 ? '纪念日当天' : '前后 $n 天'),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _window = value ?? 1),
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<bool>(
              key: const ValueKey('anniversary-repeat'),
              value: _repeat,
              decoration: const InputDecoration(labelText: '重复'),
              items: const [
                DropdownMenuItem(value: true, child: Text('每年重复')),
                DropdownMenuItem(value: false, child: Text('不重复')),
              ],
              onChanged: (value) => setState(() => _repeat = value ?? true),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('当天提醒'),
              value: _reminder,
              onChanged: (value) => setState(() => _reminder = value),
            ),
            if (_reminder)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('提醒时间'),
                trailing: Text(_reminderTime.format(context)),
                onTap: () async {
                  final value = await showTimePicker(
                    context: context,
                    initialTime: _reminderTime,
                  );
                  if (value != null && mounted)
                    setState(() => _reminderTime = value);
                },
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                if (_title.text.trim().isEmpty) {
                  setState(() => _error = '请输入名称');
                  return;
                }
                Navigator.pop(
                  context,
                  Anniversary(
                    id: widget.event?.id ?? newId(),
                    title: _title.text.trim(),
                    startDate: _date,
                    coverPhotoId: widget.event?.coverPhotoId,
                    windowDays: _window,
                    repeatYearly: _repeat,
                    reminderEnabled: _reminder,
                    reminderMinute:
                        _reminderTime.hour * 60 + _reminderTime.minute,
                    coverMode: widget.event?.coverMode ?? CoverMode.fixed,
                    coverSource: widget.event?.coverSource ?? CoverSource.all,
                    coverYear: widget.event?.coverYear,
                    coverPhotoIds: widget.event?.coverPhotoIds ?? [],
                    coverIntervalSeconds:
                        widget.event?.coverIntervalSeconds ?? 10,
                    coverChangeMinute: widget.event?.coverChangeMinute ?? 540,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    ),
  );
}

// Match the date shown in the editor, while accepting common pasted formats
// and eight digits from phone keyboards that have no date separator.
class _AnniversaryCalendarDelegate extends GregorianCalendarDelegate {
  const _AnniversaryCalendarDelegate();

  @override
  String formatCompactDate(
    DateTime date,
    MaterialLocalizations localizations,
  ) => dateLabel(CalendarDate.fromDateTime(date).iso);

  @override
  String dateHelpText(MaterialLocalizations localizations) => 'YYYY.MM.DD';

  @override
  DateTime? parseCompactDate(
    String? input,
    MaterialLocalizations localizations,
  ) {
    final text = input?.trim() ?? '';
    final separated = RegExp(
      r'^(\d{4})([./-])(\d{1,2})\2(\d{1,2})$',
    ).firstMatch(text);
    final compact = RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(text);
    if (separated == null && compact == null) return null;
    final year = int.parse(separated?.group(1) ?? compact!.group(1)!);
    final month = int.parse(separated?.group(3) ?? compact!.group(2)!);
    final day = int.parse(separated?.group(4) ?? compact!.group(3)!);
    try {
      // CalendarDate rejects overflow (e.g. February 30) rather than rolling
      // into the next month as DateTime's constructor would.
      final date = CalendarDate(year, month, day);
      return DateTime(date.year, date.month, date.day);
    } on FormatException {
      return null;
    }
  }
}
