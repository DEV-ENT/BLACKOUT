package it.blackout.mesh

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.text.DateFormat
import java.util.Date
import kotlin.math.roundToInt

/** Phone battery level in percent, or null if unknown. */
fun batteryPercent(c: Context): Int? =
    c.getSystemService(BatteryManager::class.java)?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)?.takeIf { it in 0..100 }

/** "just now", "5 min ago", "2 h ago", "3 d ago". */
fun ago(ts: Long, now: Long = System.currentTimeMillis()): String {
    val s = (now - ts) / 1000
    return when {
        s < 60 -> "just now"
        s < 3600 -> "${s / 60} min ago"
        s < 86_400 -> "${s / 3600} h ago"
        else -> "${s / 86_400} d ago"
    }
}

fun clock(c: Context, ts: Long): String = android.text.format.DateFormat.getTimeFormat(c).format(Date(ts))

/** Positions for check-ins, places and the compass. Only while the app is open; never in the background. */
object Locator {
    fun allowed(c: Context) = c.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        c.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    /** Age from the phone's uptime clock: a fix's wall-clock time can be off (GPS time, emulators). */
    private fun ageMs(l: Location) = (android.os.SystemClock.elapsedRealtimeNanos() - l.elapsedRealtimeNanos) / 1_000_000
    private fun spot(l: Location) = Spot(l.latitude, l.longitude, l.accuracy.roundToInt().takeIf { l.hasAccuracy() })

    /** A position at most 2 minutes old, waiting up to [waitMs] for a new one; null if there is none. */
    @SuppressLint("MissingPermission")
    fun fix(c: Context, waitMs: Long = 10_000, done: (Spot?) -> Unit) {
        if (!allowed(c)) { done(null); return }
        val lm = c.getSystemService(LocationManager::class.java)
        val providers = lm.getProviders(true)
        val recent = providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
            .filter { ageMs(it) < 120_000 }.minByOrNull { it.accuracy }
        if (recent != null) { done(spot(recent)); return }
        val provider = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).firstOrNull { it in providers }
            ?: providers.firstOrNull { it != LocationManager.PASSIVE_PROVIDER } ?: run { done(null); return }
        val h = Handler(Looper.getMainLooper()); var finished = false
        lateinit var listener: LocationListener
        fun finish(s: Spot?) { if (!finished) { finished = true; lm.removeUpdates(listener); done(s) } }
        listener = listener { finish(spot(it)) }
        lm.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
        h.postDelayed({ finish(null) }, waitMs)
    }

    /** Position updates every few seconds until the returned function is called. */
    @SuppressLint("MissingPermission")
    fun watch(c: Context, update: (Spot) -> Unit): () -> Unit {
        if (!allowed(c)) return {}
        val lm = c.getSystemService(LocationManager::class.java)
        val providers = lm.getProviders(true)
        providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
            .filter { ageMs(it) < 600_000 }.minByOrNull { it.accuracy }?.let { update(spot(it)) }
        val l = listener { update(spot(it)) }
        for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) if (p in providers)
            lm.requestLocationUpdates(p, 3_000L, 2f, l, Looper.getMainLooper())
        return { lm.removeUpdates(l) }
    }

    /** All four methods, so older Android versions (which have no defaults for the last three) don't crash. */
    private fun listener(got: (Location) -> Unit) = object : LocationListener {
        override fun onLocationChanged(l: Location) = got(l)
        override fun onProviderEnabled(p: String) {}
        override fun onProviderDisabled(p: String) {}
        @Deprecated("Deprecated in Java") override fun onStatusChanged(p: String?, s: Int, e: Bundle?) {}
    }
}

/** Which way the top of the phone points, in degrees from north; null if the phone has no compass. */
object Compass {
    fun watch(c: Context, update: (Float?) -> Unit): () -> Unit {
        val sm = c.getSystemService(SensorManager::class.java)
        val sensor = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) ?: run { update(null); return {} }
        val rot = FloatArray(9); val o = FloatArray(3)
        val l = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                SensorManager.getRotationMatrixFromVector(rot, e.values); SensorManager.getOrientation(rot, o)
                update(((Math.toDegrees(o[0].toDouble()) + 360) % 360).toFloat())
            }
            override fun onAccuracyChanged(s: Sensor?, a: Int) {}
        }
        sm.registerListener(l, sensor, SensorManager.SENSOR_DELAY_UI)
        return { sm.unregisterListener(l) }
    }
}

/**
 * Makes a photo small enough for one packet (Photo.MAX_BYTES): JPEG, a few hundred pixels wide.
 * Bluetooth carries a few kilobytes per second, so this keeps a photo to a few seconds per hop.
 */
object PhotoShrinker {
    fun jpeg(c: Context, uri: Uri): ByteArray? = runCatching { load(c, uri)?.let(::jpeg) }.getOrNull()

    fun jpeg(image: Bitmap): ByteArray? {
        var side = 640
        while (side >= 120) {
            val small = resized(image, side)
            for (q in 60 downTo 20 step 10) {
                val b = ByteArrayOutputStream().also { small.compress(Bitmap.CompressFormat.JPEG, q, it) }.toByteArray()
                if (b.size <= Photo.MAX_BYTES) return b
            }
            side = side * 3 / 4
        }
        return null
    }

    private fun resized(b: Bitmap, maxSide: Int): Bitmap {
        val scale = maxSide.toFloat() / maxOf(b.width, b.height)
        return if (scale >= 1) b else Bitmap.createScaledBitmap(b, (b.width * scale).roundToInt().coerceAtLeast(1), (b.height * scale).roundToInt().coerceAtLeast(1), true)
    }

    /** Decodes at most about 1280 px on the long side, upright (camera photos carry their rotation in EXIF). */
    private fun load(c: Context, uri: Uri): Bitmap? =
        if (Build.VERSION.SDK_INT >= 28) ImageDecoder.decodeBitmap(ImageDecoder.createSource(c.contentResolver, uri)) { d, info, _ ->
            val s = 1280f / maxOf(info.size.width, info.size.height)
            if (s < 1) d.setTargetSize((info.size.width * s).roundToInt(), (info.size.height * s).roundToInt())
            d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            c.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1; while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 1280) sample *= 2
            c.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
        }
}

/** A QR code as a black-on-white bitmap, made on the phone. */
fun qrBitmap(text: String, size: Int = 720): Bitmap {
    val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 1))
    val px = IntArray(size * size) { if (m.get(it % size, it / size)) 0xFF000000.toInt() else 0xFFFFFFFF.toInt() }
    return Bitmap.createBitmap(px, size, size, Bitmap.Config.ARGB_8888)
}

/** The group in use and the ones the user switched away from, so they can come back (like the iPhone's SavedGroups). */
data class SavedGroup(val name: String, val code: String)

object Groups {
    private fun prefs(c: Context) = c.getSharedPreferences("mesh", 0)
    fun current(c: Context) = prefs(c).getString("code", null)?.let { SavedGroup(prefs(c).getString("groupName", null) ?: "Group", it) }
    fun others(c: Context): List<SavedGroup> {
        val cur = prefs(c).getString("code", null)
        val a = runCatching { JSONArray(prefs(c).getString("groups", "[]")) }.getOrDefault(JSONArray())
        return (0 until a.length()).map { a.getJSONObject(it) }.map { SavedGroup(it.optString("name", "Group"), it.optString("code")) }
            .filter { it.code.isNotEmpty() && it.code != cur }
    }
    private fun remember(c: Context, g: SavedGroup) {
        val list = (listOf(g) + others(c).filter { it.code != g.code }).take(20)
        prefs(c).edit().putString("groups", JSONArray(list.map { JSONObject().put("name", it.name).put("code", it.code) }).toString()).apply()
    }
    /** First setup: saves the name and group. The mesh service starts afterwards. */
    fun setUp(c: Context, name: String, g: SavedGroup) {
        prefs(c).edit().putString("name", name).putString("code", g.code).putString("groupName", g.name).apply()
    }
    /** Shows another group's messages; this group's stay on the phone. */
    fun switchTo(c: Context, g: SavedGroup) {
        current(c)?.let { remember(c, it) }
        prefs(c).edit().putString("code", g.code).putString("groupName", g.name).apply()
        MeshEngine.switchGroup(g.code)
    }
}

/** Alerts for new group messages while DarkProof is not on screen. Made on the phone: no internet needed. */
object Notifier {
    private const val MESSAGES = "messages"; private const val HELP = "help"
    @Volatile var onScreen = false

    fun setUp(c: Context) {
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(MESSAGES, "Messages and check-ins", NotificationManager.IMPORTANCE_DEFAULT))
        nm.createNotificationChannel(NotificationChannel(HELP, "Someone needs help", NotificationManager.IMPORTANCE_HIGH))
        MeshEngine.onIncoming = { m -> received(c.applicationContext, m) }
    }

    private fun received(c: Context, m: Message) {
        if (onScreen) return
        if (c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED && Build.VERSION.SDK_INT >= 33) return
        val group = Groups.current(c)?.name ?: "your group"
        val check = CheckIn.of(m.text)
        val (title, body) = when (check) {
            CheckIn.HELP -> "${m.name} needs help" to "Open DarkProof to see where they are."
            CheckIn.SAFE -> "${m.name} is safe" to group
            null -> "${m.name} · $group" to (if (m.photo != null) Photo.text(Photo.caption(m.text)) else m.text)
        }
        val open = PendingIntent.getActivity(c, 0, Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = android.app.Notification.Builder(c, if (check == CheckIn.HELP) HELP else MESSAGES)
            .setSmallIcon(R.drawable.ic_notifications).setContentTitle(title).setContentText(body)
            .setStyle(android.app.Notification.BigTextStyle().bigText(body))
            .setContentIntent(open).setAutoCancel(true).setGroup("group").build()
        // Help alerts each get their own notification; the rest replace one per person.
        val id = if (check == CheckIn.HELP) m.id.hashCode() else m.sender.hashCode()
        c.getSystemService(NotificationManager::class.java).notify(id, n)
    }
}

/** Formats a day or time for the chat. */
fun fullTime(ts: Long): String = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(ts))
