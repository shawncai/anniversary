package com.shiri.anniversary

import android.app.Activity
import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.hardware.display.DisplayManager
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.util.AtomicFile
import android.view.Display
import android.view.View
import android.widget.ArrayAdapter
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.RemoteViews
import android.widget.TextView
import org.json.JSONObject
import java.io.File
import java.time.LocalDate

internal object WidgetStore {
    private fun snapshotFile(context: Context) = AtomicFile(File(context.filesDir, "widget-snapshot.json"))
    fun read(context: Context): JSONObject = try { JSONObject(snapshotFile(context).openRead().bufferedReader().use { it.readText() }) }
        catch (_: Exception) { JSONObject().put("events", org.json.JSONArray()) }
    fun events(context: Context): List<JSONObject> = read(context).optJSONArray("events")?.let { array ->
        (0 until array.length()).mapNotNull { array.optJSONObject(it) }
    } ?: emptyList()
    fun save(context: Context, text: String, coverPath: String?) {
        val json = JSONObject(text)
        require(json.getInt("version") == 1) { "Unsupported widget snapshot" }
        val events = json.getJSONArray("events")
        require(events.length() <= 1000) { "Too many widget events" }
        val folder = File(context.filesDir, "widget-covers").apply { mkdirs() }
        for (index in 0 until events.length()) {
            val event = events.getJSONObject(index)
            LocalDate.parse(event.getString("startDate"))
            val id = event.getString("id")
            require(id.length <= 256) { "Invalid event identifier" }
            val sourcePath = event.optString("coverPath").takeIf { it.isNotEmpty() && it != "null" }
                ?: coverPath?.takeIf { id == json.optString("selectedEventId") }
            val source = sourcePath?.let { File(it).canonicalFile }
            val root = context.filesDir.canonicalPath + File.separator
            if (source != null && source.isFile && source.path.startsWith(root)) {
                val destination = File(folder, java.security.MessageDigest.getInstance("SHA-256").digest(id.toByteArray()).joinToString("") { "%02x".format(it) } + ".jpg")
                val atomic = AtomicFile(destination)
                val stream = atomic.startWrite()
                try { source.inputStream().use { it.copyTo(stream) }; atomic.finishWrite(stream) }
                catch (error: Exception) { atomic.failWrite(stream); throw error }
                event.put("coverPath", destination.absolutePath)
            } else event.remove("coverPath")
        }
        val atomic = snapshotFile(context)
        val stream = atomic.startWrite()
        try { stream.write(json.toString().toByteArray()); atomic.finishWrite(stream) }
        catch (error: Exception) { atomic.failWrite(stream); throw error }
    }
    fun preferences(context: Context) = context.getSharedPreferences("widget-selections", Context.MODE_PRIVATE)
    fun selected(context: Context, id: Int): JSONObject? {
        val events = events(context)
        val selected = preferences(context).getString(id.toString(), null) ?: read(context).optString("selectedEventId")
        return events.firstOrNull { it.optString("id") == selected } ?: events.firstOrNull()
    }
    fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, ShiriWidgetProvider::class.java))
        ids.forEach { ShiriWidgetProvider.render(context, manager, it) }
        ShiriWidgetProvider.scheduleNext(context)
    }
}

class ShiriWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { render(context, manager, it) }; scheduleNext(context) }
    override fun onEnabled(context: Context) { scheduleNext(context) }
    override fun onDisabled(context: Context) { (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(midnightIntent(context)) }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) { render(context, manager, id) }
    override fun onDeleted(context: Context, ids: IntArray) { WidgetStore.preferences(context).edit().also { editor -> ids.forEach { editor.remove(it.toString()) } }.apply() }
    override fun onRestored(context: Context, oldIds: IntArray, newIds: IntArray) {
        val preferences = WidgetStore.preferences(context)
        val editor = preferences.edit()
        oldIds.zip(newIds).forEach { (old, new) -> editor.putString(new.toString(), preferences.getString(old.toString(), null)).remove(old.toString()) }
        editor.apply(); WidgetStore.updateAll(context)
    }
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action in setOf(Intent.ACTION_DATE_CHANGED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED, "com.shiri.anniversary.WIDGET_MIDNIGHT")) WidgetStore.updateAll(context)
    }
    companion object {
        private fun midnightIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(context, 0,
            Intent(context, ShiriWidgetProvider::class.java).setAction("com.shiri.anniversary.WIDGET_MIDNIGHT"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun scheduleNext(context: Context) {
            val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val widgets = AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, ShiriWidgetProvider::class.java))
            if (widgets.isEmpty()) {
                // A queued update can arrive after the last widget was removed.
                alarms.cancel(midnightIntent(context))
                return
            }
            val next = LocalDate.now().plusDays(1).atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli() + 1000
            alarms.setAndAllowWhileIdle(AlarmManager.RTC, next, midnightIntent(context))
        }
        fun render(context: Context, manager: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, R.layout.shiri_widget)
            val event = WidgetStore.selected(context, id)
            val link = if (event == null) Uri.parse("shiri://anniversary") else Uri.Builder().scheme("shiri").authority("anniversary").appendPath(event.optString("id")).build()
            val intent = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(link).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            views.setOnClickPendingIntent(R.id.widget_root, PendingIntent.getActivity(context, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            views.setViewVisibility(R.id.widget_image, View.GONE)
            views.setInt(R.id.widget_scrim, "setBackgroundColor", Color.TRANSPARENT)
            views.setInt(R.id.widget_root, "setBackgroundColor", Color.WHITE)
            var foreground = Color.rgb(16, 16, 20)
            if (event == null) {
                views.setTextViewText(R.id.widget_title, "拾日")
                views.setTextViewText(R.id.widget_days, "＋")
                views.setTextViewText(R.id.widget_next, "添加纪念日")
                views.setTextViewText(R.id.widget_elapsed, "")
            } else {
                val start = LocalDate.parse(event.getString("startDate"))
                val today = LocalDate.now()
                val counts = WidgetDates.calculate(start, today, event.optBoolean("repeatYearly", true))
                val next = counts.nextDate
                val countdown = counts.countdown
                val elapsed = counts.elapsed
                views.setTextViewText(R.id.widget_title, event.optString("title").take(40))
                views.setTextViewText(R.id.widget_days, if (!event.optBoolean("repeatYearly", true) && today.isAfter(start)) "${counts.elapsed} 天前" else if (countdown == 0L) "就是今天" else "$countdown 天后")
                views.setTextViewText(R.id.widget_next, next.toString().replace('-', '.'))
                views.setTextViewText(R.id.widget_elapsed, "已走过 $elapsed 天")
                val cover = event.optString("coverPath").takeIf { it.isNotBlank() }?.let { File(it) }
                if (cover?.isFile == true) {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(cover.absolutePath, bounds)
                    // RemoteViews has a screen-size-based bitmap budget. A fixed 700px
                    // cover exceeds it on compact screens even when the widget is small.
                    val display = context.resources.displayMetrics
                    val physicalMode = (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager)
                        .getDisplay(Display.DEFAULT_DISPLAY)?.mode
                    val physicalPixels = physicalMode?.let { it.physicalWidth.toLong() * it.physicalHeight } ?: Long.MAX_VALUE
                    val screenPixels = minOf(display.widthPixels.toLong() * display.heightPixels, physicalPixels)
                    val pixelBudget = maxOf(1L, screenPixels * 3 / 4)
                    val longestEdge = kotlin.math.sqrt(pixelBudget.toDouble()).toInt().coerceIn(64, 900)
                    val decode = BitmapFactory.Options().apply {
                        var sample = 1
                        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > longestEdge) sample *= 2
                        inSampleSize = sample
                        inPreferredConfig = Bitmap.Config.ARGB_8888
                        inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
                    }
                    BitmapFactory.decodeFile(cover.absolutePath, decode)?.let { bitmap ->
                        views.setImageViewBitmap(R.id.widget_image, bitmap)
                        views.setViewVisibility(R.id.widget_image, View.VISIBLE)
                        val light = event.optBoolean("lightText", true)
                        foreground = if (light) Color.WHITE else Color.rgb(16, 16, 20)
                        views.setInt(R.id.widget_scrim, "setBackgroundColor", if (light) 0x40000000 else 0x28FFFFFF)
                    }
                }
            }
            listOf(R.id.widget_title, R.id.widget_days, R.id.widget_next, R.id.widget_elapsed).forEach { views.setTextColor(it, foreground) }
            manager.updateAppWidget(id, views)
        }
    }
}

class ShiriWidgetConfigureActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        val events = WidgetStore.events(this)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
            val inset = (24 * resources.displayMetrics.density).toInt()
            setPadding(inset, inset * 2, inset, inset)
        }
        val heading = TextView(this).apply { text = "选择纪念日"; textSize = 22f; setTextColor(Color.BLACK); setPadding(0, 0, 0, 24) }
        layout.addView(heading)
        if (events.isEmpty()) {
            layout.addView(TextView(this).apply { text = "先在拾日添加一个纪念日"; textSize = 16f; setTextColor(Color.DKGRAY) })
        } else {
            layout.addView(ListView(this).apply {
                adapter = ArrayAdapter(this@ShiriWidgetConfigureActivity, android.R.layout.simple_list_item_1, events.map { "${it.optString("title")}  ·  ${it.optString("startDate")}" })
                setOnItemClickListener { _, _, position, _ ->
                    WidgetStore.preferences(this@ShiriWidgetConfigureActivity).edit().putString(id.toString(), events[position].getString("id")).apply()
                    ShiriWidgetProvider.render(this@ShiriWidgetConfigureActivity, AppWidgetManager.getInstance(this@ShiriWidgetConfigureActivity), id)
                    setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id))
                    finish()
                }
            })
        }
        setContentView(layout)
    }
}
