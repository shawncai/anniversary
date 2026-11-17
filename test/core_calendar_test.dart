import 'package:flutter_test/flutter_test.dart';
import 'package:anniversary/core/calendar.dart';

void main() {
  test('design example and start day zero', () {
    final start = CalendarDate.parse('2022-11-20');
    final result = anniversaryProgress(
      start,
      today: CalendarDate(2026, 11, 13),
    );
    expect(result.elapsedDays, 1454);
    expect(result.countdownDays, 7);
    expect(result.anniversaryNumber, 4);
    expect(result.nextDate.iso, '2026-11-20');
    expect(anniversaryProgress(start, today: start).elapsedDays, 0);
    expect(anniversaryProgress(start, today: start).countdownDays, 0);
  });

  test('anniversary today is zero and tomorrow targets following year', () {
    final start = CalendarDate(2022, 11, 20);
    expect(
      anniversaryProgress(
        start,
        today: CalendarDate(2026, 11, 20),
      ).countdownDays,
      0,
    );
    expect(
      anniversaryProgress(
        start,
        today: CalendarDate(2026, 11, 21),
      ).nextDate.iso,
      '2027-11-20',
    );
  });

  test(
    'future first date never gives negative elapsed or earlier recurrence',
    () {
      final result = anniversaryProgress(
        CalendarDate(2030, 1, 1),
        today: CalendarDate(2026, 11, 13),
      );
      expect(result.elapsedDays, 0);
      expect(result.anniversaryNumber, 0);
      expect(result.nextDate.iso, '2030-01-01');
    },
  );

  test('Feb 29 becomes Feb 28 only in non leap years', () {
    final start = CalendarDate(2020, 2, 29);
    expect(
      anniversaryProgress(
        start,
        today: CalendarDate(2023, 2, 28),
      ).countdownDays,
      0,
    );
    expect(
      anniversaryProgress(start, today: CalendarDate(2023, 3, 1)).nextDate.iso,
      '2024-02-29',
    );
    expect(isLeapYear(1900), false);
    expect(isLeapYear(2000), true);
    expect(isLeapYear(2100), false);
  });

  test('calendar differences ignore DST, hours and milliseconds', () {
    expect(CalendarDate(2026, 3, 9).daysSince(CalendarDate(2026, 3, 8)), 1);
    expect(CalendarDate(2026, 11, 2).daysSince(CalendarDate(2026, 11, 1)), 1);
    expect(CalendarDate(2026, 12, 31).addDays(1).iso, '2027-01-01');
  });

  test(
    'suggestion windows cross years, respect start and include leap mapping',
    () {
      expect(
        isPhotoInAnniversaryWindow(
          CalendarDate(2026, 12, 31),
          CalendarDate(2020, 1, 1),
        ),
        true,
      );
      expect(
        isPhotoInAnniversaryWindow(
          CalendarDate(2027, 1, 1),
          CalendarDate(2020, 12, 31),
        ),
        true,
      );
      expect(
        isPhotoInAnniversaryWindow(
          CalendarDate(2019, 12, 31),
          CalendarDate(2020, 1, 1),
        ),
        false,
      );
      expect(
        isPhotoInAnniversaryWindow(
          CalendarDate(2023, 2, 28),
          CalendarDate(2020, 2, 29),
          windowDays: 0,
        ),
        true,
      );
      expect(
        isPhotoInAnniversaryWindow(
          CalendarDate(2026, 12, 29),
          CalendarDate(2020, 1, 1),
        ),
        false,
      );
    },
  );

  test('rejects normalized malformed dates and excessive windows', () {
    expect(() => CalendarDate.parse('2025-02-29'), throwsFormatException);
    expect(() => CalendarDate.parse('2026-2-1'), throwsFormatException);
    expect(() => CalendarDate(2026, 13, 1), throwsFormatException);
    expect(
      () => isPhotoInAnniversaryWindow(
        CalendarDate.today(),
        CalendarDate(2020, 1, 1),
        windowDays: 32,
      ),
      throwsArgumentError,
    );
  });

  test(
    'photo groups follow anniversary year across both sides of New Year',
    () {
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2027, 1, 1),
          CalendarDate(2020, 12, 31),
        ),
        2026,
      );
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2026, 12, 31),
          CalendarDate(2020, 1, 1),
        ),
        2027,
      );
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2027, 1, 2),
          CalendarDate(2020, 12, 31),
          windowDays: 1,
        ),
        2027,
        reason: 'A manual photo outside the window retains its capture year',
      );
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2027, 1, 2),
          CalendarDate(2020, 12, 31),
          windowDays: 3,
        ),
        2026,
      );
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2026, 12, 31),
          CalendarDate(2020, 12, 31),
          windowDays: 0,
        ),
        2026,
      );
    },
  );

  test(
    'photo grouping uses leap-day mapping and never chooses a pre-event occurrence',
    () {
      final first = CalendarDate(2020, 2, 29);
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2023, 2, 28),
          first,
          windowDays: 0,
        ),
        2023,
      );
      expect(anniversaryYearForPhoto(CalendarDate(2024, 3, 1), first), 2024);
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2019, 12, 31),
          CalendarDate(2020, 1, 1),
        ),
        2019,
      );
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2020, 1, 1),
          CalendarDate(2020, 12, 31),
        ),
        2020,
      );
      expect(
        anniversaryYearForPhoto(CalendarDate(1, 1, 1), CalendarDate(1, 1, 1)),
        1,
      );
      expect(
        anniversaryYearForPhoto(
          CalendarDate(9999, 12, 31),
          CalendarDate(2020, 12, 31),
        ),
        9999,
      );
    },
  );

  test(
    'photo grouping respects the inclusive 31-day window without broadening it',
    () {
      final first = CalendarDate(2020, 1, 1);
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2026, 12, 1),
          first,
          windowDays: 31,
        ),
        2027,
      );
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2026, 11, 30),
          first,
          windowDays: 31,
        ),
        2026,
      );
      expect(
        anniversaryYearForPhoto(
          CalendarDate(2027, 1, 31),
          CalendarDate(2020, 12, 31),
          windowDays: 31,
        ),
        2026,
      );
      expect(
        () => anniversaryYearForPhoto(
          CalendarDate(2024, 7, 2),
          first,
          windowDays: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => anniversaryYearForPhoto(
          CalendarDate(2024, 7, 2),
          first,
          windowDays: 32,
        ),
        throwsArgumentError,
      );
    },
  );
}
