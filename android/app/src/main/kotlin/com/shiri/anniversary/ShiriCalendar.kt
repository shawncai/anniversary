package com.shiri.anniversary

import android.content.ContentProviderOperation
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.provider.CalendarContract
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Reminders
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/** A dedicated LOCAL calendar: never selects a Google/Exchange account. */
internal class ShiriCalendar(private val context: Context) {
    private val resolver get() = context.contentResolver
    private val account = "com.shiri.anniversary.local"
    private fun localCalendar(): Long {
        resolver.query(Calendars.CONTENT_URI, arrayOf(Calendars._ID),
            "account_name = ? AND account_type = ? AND name = ?",
            arrayOf(account, CalendarContract.ACCOUNT_TYPE_LOCAL, "shiri"), null)?.use {
            if (it.moveToFirst()) return it.getLong(0)
        }
        val uri = Calendars.CONTENT_URI.buildUpon()
            .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
            .appendQueryParameter(Calendars.ACCOUNT_NAME, account)
            .appendQueryParameter(Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL).build()
        val values = ContentValues().apply {
            put(Calendars.ACCOUNT_NAME, account); put(Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
            put(Calendars.NAME, "shiri"); put(Calendars.CALENDAR_DISPLAY_NAME, "拾日 · 本机")
            put(Calendars.CALENDAR_COLOR, 0xff4a3fff.toInt())
            put(Calendars.CALENDAR_ACCESS_LEVEL, Calendars.CAL_ACCESS_OWNER)
            put(Calendars.OWNER_ACCOUNT, account); put(Calendars.VISIBLE, 1); put(Calendars.SYNC_EVENTS, 1)
            put(Calendars.CALENDAR_TIME_ZONE, ZoneId.systemDefault().id)
            put(Calendars.MAX_REMINDERS, 1); put(Calendars.ALLOWED_REMINDERS, Reminders.METHOD_ALERT.toString())
        }
        return ContentUris.parseId(resolver.insert(uri, values) ?: error("无法建立本机日历"))
    }

    @Synchronized fun sync(args: Map<String, Any?>): String {
        val id = args["id"] as? String ?: error("无效纪念日")
        require(Regex("[A-Za-z0-9_-]{1,128}").matches(id))
        val enabled = args["reminderEnabled"] as? Boolean ?: false
        val prefs = context.getSharedPreferences("shiri-calendar", Context.MODE_PRIVATE)
        // A fresh disabled event never requests access or creates a calendar.
        if (!enabled && !prefs.contains("event-$id")) return "当天提醒已关闭"
        val title = args["title"] as? String ?: error("缺少名称")
        require(title.isNotBlank() && title.length <= 200)
        val first = LocalDate.parse(args["startDate"] as String)
        val yearly = args["repeatYearly"] as? Boolean ?: true
        val minute = (args["reminderMinute"] as? Number)?.toInt() ?: 540
        require(minute in 0..1439)
        val now = ZonedDateTime.now()
        val date = if (yearly) WidgetDates.calculate(first, now.toLocalDate()).nextDate else first
        val start = date.atTime(LocalTime.of(minute / 60, minute % 60)).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val calendar = localCalendar()
        val link = "shiri://anniversary/$id"
        var existing: Long? = null
        resolver.query(Events.CONTENT_URI, arrayOf(Events._ID),
            "calendar_id = ? AND customAppPackage = ? AND customAppUri = ? AND deleted = ?",
            arrayOf(calendar.toString(), context.packageName, link, "0"), null)?.use { if (it.moveToFirst()) existing = it.getLong(0) }
        val values = ContentValues().apply {
            put(Events.CALENDAR_ID, calendar); put(Events.TITLE, title)
            put(Events.DTSTART, start); put(Events.EVENT_TIMEZONE, ZoneId.systemDefault().id)
            put(Events.ALL_DAY, 0); put(Events.HAS_ALARM, if (enabled) 1 else 0)
            put(Events.CUSTOM_APP_PACKAGE, context.packageName); put(Events.CUSTOM_APP_URI, link)
            if (yearly) {
                put(Events.RRULE, if (first.monthValue == 2 && first.dayOfMonth == 29) "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1" else "FREQ=YEARLY")
                put(Events.DURATION, "PT15M"); putNull(Events.DTEND)
            } else {
                putNull(Events.RRULE); putNull(Events.DURATION); put(Events.DTEND, start + 900000)
            }
        }
        val operations = arrayListOf<ContentProviderOperation>()
        if (existing == null) {
            operations.add(ContentProviderOperation.newInsert(Events.CONTENT_URI).withValues(values).build())
        } else {
            operations.add(ContentProviderOperation.newUpdate(ContentUris.withAppendedId(Events.CONTENT_URI, existing!!)).withValues(values).build())
            // Recover the owned zero-minute alarm after app reinstall as well.
            // Nonzero user-added alarms are left alone.
            operations.add(ContentProviderOperation.newDelete(Reminders.CONTENT_URI)
                .withSelection("event_id = ? AND minutes = ? AND method = ?", arrayOf(existing.toString(), "0", Reminders.METHOD_ALERT.toString())).build())
        }
        if (enabled) {
            val reminder = ContentProviderOperation.newInsert(Reminders.CONTENT_URI)
                .withValue(Reminders.MINUTES, 0).withValue(Reminders.METHOD, Reminders.METHOD_ALERT)
            if (existing == null) reminder.withValueBackReference(Reminders.EVENT_ID, 0)
            else reminder.withValue(Reminders.EVENT_ID, existing)
            operations.add(reminder.build())
        }
        val results = resolver.applyBatch(CalendarContract.AUTHORITY, operations)
        val eventId = existing ?: ContentUris.parseId(results.first().uri!!)
        prefs.edit().putLong("event-$id", eventId)
            .putLong("alarm-$id", if (enabled) ContentUris.parseId(results.last().uri!!) else -1).apply()
        if (!enabled) return "当天提醒已关闭"
        if (!yearly && start < now.toInstant().toEpochMilli()) return "已加入本机日历；提醒时间已过，不会补发"
        return if (yearly) "已设置每年当天的本机日历提醒" else "已设置一次本机日历提醒"
    }
}
