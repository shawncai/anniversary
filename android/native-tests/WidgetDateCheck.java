package com.shiri.anniversary;

import java.time.LocalDate;

public final class WidgetDateCheck {
    private static WidgetDayCounts calculate(String start, String today) {
        return WidgetDates.INSTANCE.calculate(LocalDate.parse(start), LocalDate.parse(today));
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    public static void main(String[] args) {
        WidgetDayCounts reference = calculate("2022-11-20", "2026-11-13");
        check(reference.getElapsed() == 1454 && reference.getCountdown() == 7, "Reference design day counts");
        WidgetDayCounts today = calculate("2022-11-20", "2026-11-20");
        check(today.getCountdown() == 0 && today.getNextDate().toString().equals("2026-11-20"), "Anniversary today");
        check(calculate("2026-11-20", "2026-11-20").getElapsed() == 0, "Start date is day zero");
        WidgetDayCounts future = calculate("2027-01-01", "2026-11-13");
        check(future.getElapsed() == 0 && future.getCountdown() == 49, "Future first event date");
        check(calculate("2020-02-29", "2023-02-28").getCountdown() == 0, "Leap day maps to February 28");
        WidgetDayCounts afterLeap = calculate("2020-02-29", "2023-03-01");
        check(afterLeap.getNextDate().toString().equals("2024-02-29") && afterLeap.getCountdown() == 365, "Next leap anniversary");
        check(calculate("2025-03-08", "2025-03-10").getElapsed() == 2, "Calendar-day count over DST");
        check(calculate("2022-01-01", "2026-12-31").getCountdown() == 1, "Year-boundary countdown");
        WidgetDayCounts once = WidgetDates.INSTANCE.calculate(LocalDate.parse("2020-02-29"), LocalDate.parse("2026-02-28"), false);
        check(once.getCountdown() == 0 && once.getNextDate().toString().equals("2020-02-29"), "One-time dates do not recur");
        System.out.println("PASS: widget reference dates, day zero, today, future dates, leap years, DST, year boundary");
    }
}
