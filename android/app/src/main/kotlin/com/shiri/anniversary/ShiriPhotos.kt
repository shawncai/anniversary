package com.shiri.anniversary

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.io.File
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.Locale
import java.util.UUID
import kotlin.math.abs

internal class ShiriPhotos(private val context: Context) {
    private val resolver get() = context.contentResolver
    private val imports get() = File(context.filesDir, "imports").apply { mkdirs() }

    fun importUris(uris: List<Uri>): List<Map<String, Any>> {
        val imported = mutableListOf<Map<String, Any>>()
        try { uris.take(100).forEach { imported.add(importUri(it)) }; return imported }
        catch (error: Exception) {
            imported.forEach { photo -> File(photo.getValue("originalPath") as String).delete(); File(photo.getValue("thumbnailPath") as String).delete() }
            throw error
        }
    }

    fun scan(startYear: Int, month: Int, day: Int, windowDays: Int, offset: Int, limit: Int): Map<String, Any?> {
        require(startYear in 1..9999 && month in 1..12 && day in 1..31 && offset >= 0 && windowDays in 0..31) { "Invalid date filter" }
        val firstDate = LocalDate.of(startYear, month, day)
        val pageSize = limit.coerceIn(1, 100)
        val items = mutableListOf<Map<String, Any>>()
        var matched = 0
        var unavailable = 0
        var nextOffset: Int? = null
        val projection = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DATE_TAKEN, MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.DATE_MODIFIED)
        try {
          resolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, projection, null, null, "${MediaStore.Images.Media.DATE_TAKEN} DESC, ${MediaStore.Images.Media._ID} DESC")?.use { cursor ->
            while (cursor.moveToNext()) {
                val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cursor.getLong(0))
                val taken = cursor.getLong(1).takeIf { it != 0L }
                    ?: try { resolver.openInputStream(uri)?.use { exifDate(ExifInterface(it)) } } catch (_: java.io.IOException) { null } catch (_: SecurityException) { null }
                    ?: (cursor.getLong(2).takeIf { it > 0 } ?: cursor.getLong(3).takeIf { it > 0 })?.times(1000L)
                    ?: continue
                val date = Instant.ofEpochMilli(taken).atZone(ZoneId.systemDefault()).toLocalDate()
                if (date.year !in 1..9999 || date < firstDate || !matches(date, month, day, windowDays)) continue
                if (matched++ < offset) continue
                if (items.size + unavailable >= pageSize) { nextOffset = matched - 1; break }
                try { items.add(importUri(uri, taken)) }
                catch (_: java.io.IOException) { unavailable++ }
                catch (_: SecurityException) { unavailable++ }
            }
          }
        } catch (error: Exception) {
            items.forEach { photo -> File(photo.getValue("originalPath") as String).delete(); File(photo.getValue("thumbnailPath") as String).delete() }
            throw error
        }
        return mapOf("items" to items, "nextOffset" to nextOffset, "unavailable" to unavailable)
    }

    private fun matches(date: LocalDate, month: Int, day: Int, window: Int): Boolean =
        (-1..1).any { delta ->
            val year = date.year + delta
            val anniversary = LocalDate.of(year, month, day.coerceAtMost(java.time.Month.of(month).length(java.time.Year.isLeap(year.toLong()))))
            abs(ChronoUnit.DAYS.between(anniversary, date)) <= window
        }

    private fun importUri(uri: Uri, fallbackTime: Long? = null): Map<String, Any> {
        require(uri.scheme == "content") { "Unsupported photo source" }
        var originalName = "photo"
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) originalName = cursor.getString(0) ?: "photo"
        }
        val mime = resolver.getType(uri) ?: "image/jpeg"
        require(mime.startsWith("image/")) { "Only photos are supported" }
        val id = UUID.randomUUID().toString()
        val ext = when (mime) { "image/heic", "image/heif" -> "heic"; "image/png" -> "png"; "image/webp" -> "webp"; "image/gif" -> "gif"; else -> "jpg" }
        val original = File(imports, "$id.$ext")
        val thumbnail = File(imports, "$id.thumb.jpg")
        try {
            resolver.openInputStream(uri)?.use { source -> original.outputStream().use { source.copyTo(it) } }
                ?: throw java.io.IOException("This photo is not available on this device")
            if (original.length() == 0L) throw java.io.IOException("The selected photo is empty")
            val exif = try { ExifInterface(original.absolutePath) } catch (_: java.io.IOException) { null }
            // Preserve the same resolved date used by the scanner. The gallery's
            // explicit DATE_TAKEN also preserves user-adjusted dates for manual picks.
            val captured = fallbackTime ?: mediaDate(uri, false) ?: exifDate(exif) ?: mediaDate(uri) ?: original.lastModified()
            makeThumbnail(original, thumbnail, exif)
            return mapOf("sourceId" to "android:$uri", "originalPath" to original.absolutePath, "thumbnailPath" to thumbnail.absolutePath,
                "capturedAt" to Instant.ofEpochMilli(captured).toString(), "originalName" to originalName, "mimeType" to mime)
        } catch (error: Exception) {
            original.delete(); thumbnail.delete()
            throw error
        }
    }

    private fun mediaDate(uri: Uri, includeFallback: Boolean = true): Long? = try {
        resolver.query(uri, arrayOf(MediaStore.Images.Media.DATE_TAKEN, MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.DATE_MODIFIED), null, null, null)?.use { c ->
            if (!c.moveToFirst()) null
            else c.getLong(0).takeIf { it != 0L } ?: if (includeFallback) ((c.getLong(1).takeIf { it > 0 } ?: c.getLong(2)).takeIf { it > 0 }?.times(1000L)) else null
        }
    } catch (_: Exception) { null }

    private fun exifDate(exif: ExifInterface?): Long? {
        val text = exif?.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL) ?: exif?.getAttribute(ExifInterface.TAG_DATETIME) ?: return null
        val offset = exif?.getAttribute("OffsetTimeOriginal")
        return try {
            val format = SimpleDateFormat(if (offset != null) "yyyy:MM:dd HH:mm:ssXXX" else "yyyy:MM:dd HH:mm:ss", Locale.US)
            format.isLenient = false
            format.parse(text + (offset ?: ""))?.time
        } catch (_: Exception) { null }
    }

    private fun makeThumbnail(source: File, target: File, exif: ExifInterface?) {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.absolutePath, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 1600) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = BitmapFactory.decodeFile(source.absolutePath, options) ?: throw java.io.IOException("This photo format cannot be decoded")
        val matrix = Matrix()
        when (exif?.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(270f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(270f)
        }
        val oriented = if (matrix.isIdentity) bitmap else Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        try { target.outputStream().use { if (!oriented.compress(Bitmap.CompressFormat.JPEG, 88, it)) throw java.io.IOException("Cannot create photo thumbnail") } }
        finally { if (oriented !== bitmap) oriented.recycle(); bitmap.recycle() }
    }
}
