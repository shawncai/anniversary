/// A calendar date without a time or timezone. Stored as YYYY-MM-DD.
class CalendarDate implements Comparable<CalendarDate> {
  CalendarDate(this.year, this.month, this.day) {
    final value = DateTime.utc(year, month, day);
    if (year < 1 ||
        year > 9999 ||
        value.year != year ||
        value.month != month ||
        value.day != day) {
      throw FormatException('无效日期');
    }
  }

  factory CalendarDate.parse(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw FormatException('日期必须为 YYYY-MM-DD');
    }
    final pieces = value.split('-').map(int.parse).toList();
    return CalendarDate(pieces[0], pieces[1], pieces[2]);
  }

  factory CalendarDate.fromDateTime(DateTime value) =>
      CalendarDate(value.year, value.month, value.day);

  factory CalendarDate.today() => CalendarDate.fromDateTime(DateTime.now());

  final int year;
  final int month;
  final int day;
  DateTime get utc => DateTime.utc(year, month, day);
  String get iso =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

  int daysSince(CalendarDate other) => utc.difference(other.utc).inDays;
  CalendarDate addDays(int days) =>
      CalendarDate.fromDateTime(utc.add(Duration(days: days)));

  @override
  int compareTo(CalendarDate other) => utc.compareTo(other.utc);
  @override
  bool operator ==(Object other) => other is CalendarDate && iso == other.iso;
  @override
  int get hashCode => iso.hashCode;
  @override
  String toString() => iso;
}

bool isLeapYear(int year) =>
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

CalendarDate occurrenceInYear(CalendarDate first, int year) => CalendarDate(
  year,
  first.month,
  first.month == 2 && first.day == 29 && !isLeapYear(year) ? 28 : first.day,
);

class AnniversaryProgress {
  const AnniversaryProgress({
    required this.elapsedDays,
    required this.countdownDays,
    required this.nextDate,
    required this.anniversaryNumber,
  });
  final int elapsedDays;
  final int countdownDays;
  final CalendarDate nextDate;
  final int anniversaryNumber;
}

AnniversaryProgress anniversaryProgress(
  CalendarDate start, {
  CalendarDate? today,
  bool repeatYearly = true,
}) {
  final current = today ?? CalendarDate.today();
  var next = start;
  if (repeatYearly && current.compareTo(start) >= 0) {
    next = occurrenceInYear(start, current.year);
    if (next.compareTo(current) < 0 && current.year < 9999) {
      next = occurrenceInYear(start, current.year + 1);
    }
  }
  final elapsed = current.daysSince(start);
  return AnniversaryProgress(
    elapsedDays: elapsed < 0 ? 0 : elapsed,
    countdownDays: next.daysSince(current).clamp(0, 3652059),
    nextDate: next,
    anniversaryNumber: next.year - start.year,
  );
}

/// Includes both sides of New Year and applies the same leap-day rule as widgets.
/// Photos predating the first event are never automatically suggested.
bool isPhotoInAnniversaryWindow(
  CalendarDate captured,
  CalendarDate first, {
  int windowDays = 1,
}) {
  if (windowDays < 0 || windowDays > 31) {
    throw ArgumentError.value(windowDays, 'windowDays', '必须在 0–31 内');
  }
  if (captured.compareTo(first) < 0) return false;
  for (final year in [captured.year - 1, captured.year, captured.year + 1]) {
    if (year < first.year || year < 1 || year > 9999) continue;
    if (captured.daysSince(occurrenceInYear(first, year)).abs() <= windowDays) {
      return true;
    }
  }
  return false;
}

/// Groups a photo by the anniversary occurrence it belongs to, rather than the
/// photo's calendar year. For example, Jan 1 can belong to the prior Dec 31.
/// Manual photos outside the window (including before the first event) keep
/// their capture year. Equidistant occurrences prefer the earlier/past one.
/// The window matches the app's 0–31 day limit. Adjacent annual occurrences
/// cannot tie within that range; the earlier-year tie rule is still explicit.
int anniversaryYearForPhoto(
  CalendarDate captured,
  CalendarDate first, {
  int windowDays = 1,
}) {
  if (windowDays < 0 || windowDays > 31) {
    throw ArgumentError.value(windowDays, 'windowDays', '必须在 0–31 内');
  }
  if (captured.compareTo(first) < 0) return captured.year;
  int? closestYear;
  var closestDistance = windowDays + 1;
  for (final year in [captured.year - 1, captured.year, captured.year + 1]) {
    if (year < first.year || year < 1 || year > 9999) continue;
    final occurrence = occurrenceInYear(first, year);
    if (occurrence.compareTo(first) < 0) continue;
    final distance = captured.daysSince(occurrence).abs();
    if (distance > windowDays) continue;
    if (distance < closestDistance ||
        (distance == closestDistance &&
            (closestYear == null || year < closestYear))) {
      closestYear = year;
      closestDistance = distance;
    }
  }
  return closestYear ?? captured.year;
}
