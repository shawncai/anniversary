package com.shiri.anniversary

import java.time.LocalDate
import java.time.Month
import java.time.Year
import java.time.temporal.ChronoUnit

internal data class WidgetDayCounts(val nextDate: LocalDate, val elapsed: Long, val countdown: Long)

/** Calendar dates keep day counts independent of daylight-saving hour changes. */
internal object WidgetDates {
    @JvmOverloads fun calculate(start: LocalDate, today: LocalDate, repeatYearly: Boolean = true): WidgetDayCounts {
        var next = if (!repeatYearly || today.isBefore(start)) start else anniversary(start, today.year)
        if (repeatYearly && next.isBefore(today)) next = anniversary(start, today.year + 1)
        return WidgetDayCounts(next, maxOf(0, ChronoUnit.DAYS.between(start, today)), maxOf(0, ChronoUnit.DAYS.between(today, next)))
    }
    private fun anniversary(start: LocalDate, year: Int): LocalDate = LocalDate.of(year, start.month,
        start.dayOfMonth.coerceAtMost(Month.of(start.monthValue).length(Year.isLeap(year.toLong()))))
}
