package com.shiri.anniversary

import android.Manifest
import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

internal class ShiriPlatform(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.shiri.anniversary/platform")
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newFixedThreadPool(2)
    private val photos = ShiriPhotos(activity)
    private val calendar = ShiriCalendar(activity)
    private val crypto = ShiriCrypto()
    private val ble = ShiriBle(activity, { channel.invokeMethod("onNearbyDevice", it) }, { channel.invokeMethod("onDiscoveryError", it) })
    private var pendingPicker: MethodChannel.Result? = null
    private var pickerCode = 0
    private var exportPath: File? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var afterPermission: (() -> Unit)? = null
    private var initialLink: String? = validLink(activity.intent)
    @Volatile private var transferGeneration = 0
    private val preferences get() = activity.getSharedPreferences("native-permissions", Activity.MODE_PRIVATE)

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "paths" -> result.success(mapOf("documents" to activity.filesDir.absolutePath, "temporary" to activity.cacheDir.absolutePath))
                "syncReminder" -> requestCalendar(call, result)
                "takeDayReminders" -> {
                    val day = call.argument<String>("date") ?: error("Missing day")
                    val ids = call.argument<List<String>>("ids") ?: emptyList()
                    val prefs = activity.getSharedPreferences("shiri-reminder-seen", Activity.MODE_PRIVATE)
                    val fresh = ids.filter { prefs.getString(it, null) != day }
                    val editor = prefs.edit(); fresh.forEach { editor.putString(it, day) }; editor.commit()
                    result.success(fresh)
                }
                "photoPermission" -> result.success(photoPermission())
                "requestPhotoPermission" -> requestPhotos(result)
                "pickPhotos" -> pickPhotos(result)
                "scanPhotos" -> {
                    if (photoPermission() !in setOf("full", "limited")) result.error("photo_permission", "请先允许访问相册，或手动选择照片", null)
                    else background(result) { photos.scan(call.number("startYear", 1), call.number("month"), call.number("day"), call.number("windowDays", 0), call.number("offset", 0), call.number("limit", 20)) }
                }
                "importFile" -> launchPicker(IMPORT_FILE, Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type = "*/*"; addCategory(Intent.CATEGORY_OPENABLE) }, result)
                "exportFile" -> {
                    require(pendingPicker == null) { "A file picker is already open" }
                    exportPath = privateFile(call.argument<String>("path") ?: error("Missing backup path"))
                    val name = (call.argument<String>("name") ?: "拾日备份.shiri").replace(Regex("[\\\\/\\p{Cntrl}]"), "_").take(120)
                    launchPicker(EXPORT_FILE, Intent(Intent.ACTION_CREATE_DOCUMENT).apply { type = "application/octet-stream"; addCategory(Intent.CATEGORY_OPENABLE); putExtra(Intent.EXTRA_TITLE, name) }, result)
                }
                "updateWidgets" -> background(result) {
                    WidgetStore.save(activity, call.argument<String>("json") ?: error("Missing widget snapshot"), call.argument<String>("coverPath"))
                    WidgetStore.updateAll(activity)
                    null
                }
                "requestPinWidget" -> {
                    val manager = AppWidgetManager.getInstance(activity)
                    result.success(manager.isRequestPinAppWidgetSupported && manager.requestPinAppWidget(ComponentName(activity, ShiriWidgetProvider::class.java), null, null))
                }
                "initialLink" -> { result.success(initialLink); initialLink = null }
                "openSettings" -> { activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))); result.success(null) }
                "deviceName" -> result.success(listOf(Build.MANUFACTURER, Build.MODEL).distinct().joinToString(" "))
                "startDiscovery" -> requestBluetooth(call, result)
                "stopDiscovery" -> { stopTransferResources(); result.success(null) }
                "cryptoKeyPair" -> {
                    val generation = transferGeneration
                    background(result) { synchronized(crypto) {
                        check(generation == transferGeneration) { "Pairing session closed" }
                        crypto.keyPair()
                    } }
                }
                "cryptoDerive" -> background(result) { crypto.derive(call.argument<String>("handle") ?: error("Missing session"), call.bytes("peerPublicKey"), call.bytes("salt")) }
                "cryptoSeal" -> background(result) { crypto.crypt(true, call.bytes("key"), call.bytes("nonce"), call.bytes("plaintext"), call.bytes("aad")) }
                "cryptoOpen" -> background(result) { crypto.crypt(false, call.bytes("key"), call.bytes("nonce"), call.bytes("ciphertext"), call.bytes("aad")) }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { result.error("native_error", error.message ?: "操作未完成", null) }
    }

    private fun photoPermission(): String {
        if (Build.VERSION.SDK_INT >= 33) {
            if (granted(Manifest.permission.READ_MEDIA_IMAGES)) return "full"
            if (Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)) return "limited"
        } else if (granted(Manifest.permission.READ_EXTERNAL_STORAGE)) return "full"
        return if (preferences.getBoolean("photos-requested", false)) "denied" else "notDetermined"
    }

    private fun requestCalendar(call: MethodCall, result: MethodChannel.Result) {
        val args = (call.arguments as? Map<*, *>)?.entries?.associate { (key, value) -> key.toString() to value } ?: emptyMap()
        val enabled = call.argument<Boolean>("reminderEnabled") ?: false
        val permissions = arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)
        val start = {
            if (!permissions.all(::granted)) {
                result.success(if (enabled) "未允许日历权限，仅在打开拾日时提醒" else "提醒已在应用内关闭；请在系统日历检查已有提醒")
            } else background(result) { calendar.sync(args) }
        }
        if (permissions.all(::granted)) start()
        else if (enabled && call.argument<Boolean>("requestPermissions") == true) {
            require(pendingPermission == null) { "请先完成当前权限请求" }
            pendingPermission = result; afterPermission = start
            activity.requestPermissions(permissions, CALENDAR_PERMISSION)
        } else if (!enabled) {
            val saved = activity.getSharedPreferences("shiri-calendar", Activity.MODE_PRIVATE).contains("event-${call.argument<String>("id")}")
            result.success(if (saved) "提醒已在应用内关闭；请在系统日历检查已有提醒" else "当天提醒已关闭")
        }
        else start()
    }

    private fun requestPhotos(result: MethodChannel.Result) {
        if (photoPermission() == "full") { result.success("full"); return }
        val permissions = when {
            Build.VERSION.SDK_INT >= 34 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
            else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        require(pendingPermission == null) { "A permission request is already open" }
        preferences.edit().putBoolean("photos-requested", true).apply()
        pendingPermission = result
        afterPermission = { result.success(photoPermission()) }
        activity.requestPermissions(permissions, PHOTO_PERMISSION)
    }

    private fun requestBluetooth(call: MethodCall, result: MethodChannel.Result) {
        val port = call.number("port")
        require(port in 0..65535) { "Invalid local endpoint" }
        val permissions = if (Build.VERSION.SDK_INT >= 31) {
            val required = mutableListOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            if (port > 0) required.add(Manifest.permission.BLUETOOTH_ADVERTISE)
            required.toTypedArray()
        } else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        val generation = transferGeneration
        val start = {
            if (generation != transferGeneration) result.error("discovery_cancelled", "附近发现已取消", null)
            else if (!permissions.all(::granted)) result.error("bluetooth_permission", "未允许附近设备权限，可使用地址连接", null)
            else ble.start(call.argument<String>("name") ?: Build.MODEL, call.argument<String>("host") ?: error("Missing local address"), port) { supported, error ->
                if (error != null && !supported) result.error("bluetooth_unavailable", error, null) else result.success(supported)
            }
        }
        if (permissions.all(::granted)) start()
        else {
            require(pendingPermission == null) { "A permission request is already open" }
            pendingPermission = result
            afterPermission = start
            activity.requestPermissions(permissions, BLUETOOTH_PERMISSION)
        }
    }

    private fun granted(permission: String) = activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    fun onRequestPermissionsResult(code: Int): Boolean {
        if (code !in setOf(PHOTO_PERMISSION, BLUETOOTH_PERMISSION, CALENDAR_PERMISSION)) return false
        val result = pendingPermission
        val action = afterPermission
        pendingPermission = null; afterPermission = null
        try { action?.invoke() } catch (error: Exception) { result?.error("permission_error", error.message, null) }
        return true
    }

    private fun pickPhotos(result: MethodChannel.Result) {
        val intent = if (Build.VERSION.SDK_INT >= 33) Intent(MediaStore.ACTION_PICK_IMAGES).apply {
            type = "image/*"; putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, minOf(100, MediaStore.getPickImagesMaxLimit()))
        } else Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type = "image/*"; addCategory(Intent.CATEGORY_OPENABLE); putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true) }
        launchPicker(PICK_PHOTOS, intent, result)
    }

    private fun launchPicker(code: Int, intent: Intent, result: MethodChannel.Result) {
        require(pendingPicker == null) { "A file picker is already open" }
        pendingPicker = result; pickerCode = code
        try { activity.startActivityForResult(intent, code) }
        catch (error: Exception) { pendingPicker = null; pickerCode = 0; exportPath = null; throw error }
    }

    fun onActivityResult(code: Int, status: Int, data: Intent?): Boolean {
        if (code !in setOf(PICK_PHOTOS, IMPORT_FILE, EXPORT_FILE)) return false
        if (code != pickerCode) return true
        val result = pendingPicker ?: return true
        val source = exportPath
        pendingPicker = null; pickerCode = 0; exportPath = null
        if (status != Activity.RESULT_OK || data == null) { result.success(if (code == EXPORT_FILE) false else null); return true }
        background(result) {
            when (code) {
                PICK_PHOTOS -> {
                    val uris = data.clipData?.let { clip -> (0 until clip.itemCount).map { clip.getItemAt(it).uri } } ?: listOfNotNull(data.data)
                    if (uris.isEmpty()) null else photos.importUris(uris.distinct())
                }
                IMPORT_FILE -> {
                    val uri = data.data ?: error("No backup was selected")
                    val target = File(activity.cacheDir, "import-${UUID.randomUUID()}.shiri")
                    try {
                        activity.contentResolver.openInputStream(uri)?.use { input -> target.outputStream().use { input.copyTo(it) } } ?: error("无法读取备份")
                        target.absolutePath
                    } catch (error: Exception) { target.delete(); throw error }
                }
                EXPORT_FILE -> {
                    val uri = data.data ?: error("No backup destination was selected")
                    require(source?.isFile == true) { "Backup is no longer available" }
                    activity.contentResolver.openOutputStream(uri, "wt")?.use { output -> source!!.inputStream().use { it.copyTo(output) } } ?: error("无法保存备份")
                    true
                }
                else -> null
            }
        }
        return true
    }

    private fun privateFile(path: String): File {
        val file = File(path).canonicalFile
        require(file.isFile && listOf(activity.filesDir, activity.cacheDir).any { file.path.startsWith(it.canonicalPath + File.separator) }) { "Backup path must be app-private" }
        return file
    }

    private fun background(result: MethodChannel.Result, task: () -> Any?) {
        executor.execute {
            try { val value = task(); handler.post { result.success(value) } }
            catch (error: Exception) { handler.post { result.error(if (error is javax.crypto.AEADBadTagException) "authentication_failed" else "native_error", error.message ?: "操作未完成", null) } }
        }
    }

    fun onNewIntent(intent: Intent) { validLink(intent)?.let { channel.invokeMethod("onDeepLink", it) } }
    private fun stopTransferResources() {
        transferGeneration++
        ble.stop()
        synchronized(crypto) { crypto.clear() }
    }
    fun onStop() { stopTransferResources() }
    fun dispose() {
        stopTransferResources()
        pendingPicker?.error("activity_closed", "操作已取消", null); pendingPicker = null
        pendingPermission?.error("activity_closed", "操作已取消", null); pendingPermission = null; afterPermission = null
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
    private fun validLink(intent: Intent?): String? = intent?.data?.takeIf { it.scheme == "shiri" && it.host == "anniversary" }?.toString()
    private fun MethodCall.number(key: String, default: Int? = null): Int = argument<Number>(key)?.toInt() ?: default ?: error("Missing $key")
    private fun MethodCall.bytes(key: String): ByteArray = argument<ByteArray>(key) ?: error("Missing $key")
    companion object { private const val PICK_PHOTOS = 7201; private const val IMPORT_FILE = 7202; private const val EXPORT_FILE = 7203; private const val PHOTO_PERMISSION = 7210; private const val BLUETOOTH_PERMISSION = 7211; private const val CALENDAR_PERMISSION = 7212 }
}
