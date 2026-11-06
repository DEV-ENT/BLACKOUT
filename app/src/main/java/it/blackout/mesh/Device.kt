package it.blackout.mesh

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.hardware.GeomagneticField
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
import android.os.PersistableBundle
import android.view.Surface
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

    /**
     * A position at most 2 minutes old, waiting up to [waitMs] for a new one; null if there is none. Returns a cancel
     * function: after it, [done] is never called (e.g. the sheet that asked was closed).
     */
    @SuppressLint("MissingPermission")
    fun fix(c: Context, waitMs: Long = 10_000, done: (Spot?) -> Unit): () -> Unit {
        if (!allowed(c)) { done(null); return {} }
        val lm = c.getSystemService(LocationManager::class.java)
        val providers = lm.getProviders(true)
        val recent = providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
            .filter { ageMs(it) < 120_000 }.minByOrNull { it.accuracy }
        if (recent != null) { done(spot(recent)); return {} }
        val provider = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).firstOrNull { it in providers }
            ?: providers.firstOrNull { it != LocationManager.PASSIVE_PROVIDER } ?: run { done(null); return {} }
        val h = Handler(Looper.getMainLooper()); var finished = false
        lateinit var listener: LocationListener
        fun finish(s: Spot?, report: Boolean = true) { if (!finished) { finished = true; lm.removeUpdates(listener); if (report) done(s) } }
        listener = listener { finish(spot(it)) }
        try { lm.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper()) } catch (_: RuntimeException) { finish(null); return {} }
        h.postDelayed({ finish(null) }, waitMs)
        return { h.post { finish(null, report = false) } }
    }

    /** Whether the phone's location setting is on (Android's switch, not DarkProof's permission). */
    fun enabled(c: Context): Boolean = runCatching {
        val lm = c.getSystemService(LocationManager::class.java)
        if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled else lm.isProviderEnabled(LocationManager.GPS_PROVIDER) || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }.getOrDefault(true)

    /** The phone's last position if it is at most 10 minutes old, without turning on GPS. */
    @SuppressLint("MissingPermission")
    fun lastKnown(c: Context): Spot? {
        if (!allowed(c)) return null
        val lm = c.getSystemService(LocationManager::class.java)
        return lm.getProviders(true).mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
            .filter { ageMs(it) < 600_000 }.minByOrNull { it.accuracy }?.let(::spot)
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
            runCatching { lm.requestLocationUpdates(p, 3_000L, 2f, l, Looper.getMainLooper()) }
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

/**
 * Which way the top of the screen points, in degrees from magnetic north; null if the phone has no compass. The sensor
 * axes are turned with the screen, so the arrow stays right in landscape too. Add [declination] for true north.
 */
object Compass {
    fun watch(c: Context, update: (Float?) -> Unit): () -> Unit {
        val sm = c.getSystemService(SensorManager::class.java)
        val sensor = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) ?: run { update(null); return {} }
        val rot = FloatArray(9); val turned = FloatArray(9); val o = FloatArray(3)
        val l = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                SensorManager.getRotationMatrixFromVector(rot, e.values)
                val (x, y) = when (screenRotation(c)) {
                    Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
                    Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
                    Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
                    else -> SensorManager.AXIS_X to SensorManager.AXIS_Y
                }
                SensorManager.remapCoordinateSystem(rot, x, y, turned); SensorManager.getOrientation(turned, o)
                update(((Math.toDegrees(o[0].toDouble()) + 360) % 360).toFloat())
            }
            override fun onAccuracyChanged(s: Sensor?, a: Int) {}
        }
        sm.registerListener(l, sensor, SensorManager.SENSOR_DELAY_UI)
        return { sm.unregisterListener(l) }
    }

    /** Degrees east of true north that magnetic north lies at [at] (Earth's field model): true = magnetic + this. */
    fun declination(at: Spot, now: Long = System.currentTimeMillis()): Float =
        runCatching { GeomagneticField(at.lat.toFloat(), at.lon.toFloat(), 0f, now).declination }.getOrDefault(0f)

    @Suppress("DEPRECATION")
    private fun screenRotation(c: Context): Int =
        (if (Build.VERSION.SDK_INT >= 30) runCatching { c.display?.rotation }.getOrNull() else null)
            ?: runCatching { c.getSystemService(android.view.WindowManager::class.java).defaultDisplay.rotation }.getOrDefault(Surface.ROTATION_0)
}

/** About how long the battery lasts, from how fast it dropped since it was last unplugged. */
object BatteryLife {
    /** Hours left at the rate of the last half hour or more, or null while that isn't known (or the phone charges). */
    fun hoursLeft(c: Context, now: Long = System.currentTimeMillis()): Int? {
        val bm = c.getSystemService(BatteryManager::class.java) ?: return null
        val pct = batteryPercent(c) ?: return null
        val prefs = c.getSharedPreferences("battery", 0)
        if (bm.isCharging) { if (prefs.contains("t")) prefs.edit().clear().apply(); return null }
        val t0 = prefs.getLong("t", 0); val p0 = prefs.getInt("p", -1)
        if (t0 == 0L || p0 < pct || now < t0) { prefs.edit().putLong("t", now).putInt("p", pct).apply(); return null }
        return estimate(pct, p0 - pct, (now - t0) / 3_600_000.0)
    }

    /** [drop] points in [hours]: meaningful after half an hour and 2 points, and only between 1 and 240 hours. */
    fun estimate(pct: Int, drop: Int, hours: Double): Int? =
        if (hours < 0.5 || drop < 2) null else (pct * hours / drop).roundToInt().takeIf { it in 1..240 }
}

/** Copies [text]; a group code is marked sensitive so Android hides it in the clipboard preview. */
fun copyText(c: Context, label: String, text: String, sensitive: Boolean = false, done: String = "Copied") {
    val clip = ClipData.newPlainText(label, text)
    if (sensitive) clip.description.extras = PersistableBundle().apply {
        putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
    }
    c.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
    if (Build.VERSION.SDK_INT < 33) android.widget.Toast.makeText(c, done, android.widget.Toast.LENGTH_SHORT).show() // Android 13+ shows its own
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

/**
 * A photo from another phone, decoded safely: its bytes are untrusted, so a header claiming a huge picture is refused
 * (it could need hundreds of MB) and the picture is decoded at most about [maxSide] pixels on its longest side.
 */
fun decodePhoto(jpeg: ByteArray, maxSide: Int = 1280): Bitmap? {
    val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, o)
    if (o.outWidth !in 1..4096 || o.outHeight !in 1..4096) return null
    var sample = 1; while (maxOf(o.outWidth, o.outHeight) / sample > maxSide) sample *= 2
    return runCatching { BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, BitmapFactory.Options().apply { inSampleSize = sample }) }.getOrNull()
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
    /** The group in use, then the others. */
    fun all(c: Context): List<SavedGroup> = listOfNotNull(current(c)) + others(c)
    fun find(c: Context, code: String?): SavedGroup? = code?.let { k -> all(c).firstOrNull { it.code == k } }
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

/**
 * People the user blocked and messages the user reported: both are hidden everywhere (chats, places, people, alerts).
 * Kept only on this phone. Reports also go to the internet relays (NostrLink) when there is internet.
 */
object Moderation {
    private fun prefs(c: Context) = c.getSharedPreferences("mesh", 0)
    @Volatile private var blockedCache: Map<String, String>? = null
    @Volatile private var hiddenCache: Set<String>? = null

    /** Blocked sender ids and the name they had. */
    fun blocked(c: Context): Map<String, String> = blockedCache ?: runCatching {
        val o = JSONObject(prefs(c).getString("blocked", "{}")!!); o.keys().asSequence().associateWith { o.getString(it) }
    }.getOrDefault(emptyMap()).also { blockedCache = it }

    fun block(c: Context, id: String, name: String) = saveBlocked(c, blocked(c) + (id to name))
    fun unblock(c: Context, id: String) = saveBlocked(c, blocked(c) - id)
    private fun saveBlocked(c: Context, m: Map<String, String>) {
        blockedCache = m; prefs(c).edit().putString("blocked", JSONObject(m).toString()).apply()
    }

    /** Ids of messages the user reported or hid. */
    fun hidden(c: Context): Set<String> = hiddenCache ?: (prefs(c).getStringSet("hidden", emptySet())!!.toSet()).also { hiddenCache = it }
    fun hide(c: Context, messageId: String) {
        val s = (hidden(c) + messageId).toList().takeLast(2_000).toSet()
        hiddenCache = s; prefs(c).edit().putStringSet("hidden", s).apply()
    }

    fun visible(c: Context, m: Message) = m.sender !in blocked(c) && m.id !in hidden(c)
}

/**
 * Alerts for new messages of every saved group. Made on the phone: no internet needed. While DarkProof is on screen,
 * someone needing help, an "are you safe?" meant for me and other groups' messages show as a banner (with a vibration
 * when it is urgent); otherwise as notifications, which open that group's chat.
 */
object Notifier {
    private const val MESSAGES = "messages"; private const val HELP = "help"
    @Volatile var onScreen = false
    /** Set by the screen while it is shown: gets the banners. Main thread. */
    var inApp: ((Alert) -> Unit)? = null

    /** [group]: the saved group's code. [ask]: offer the one-tap "I'm safe" / "I need help" answers. */
    data class Alert(val title: String, val body: String, val group: String?, val urgent: Boolean, val ask: Boolean, val messageId: String)

    fun setUp(c: Context) {
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(MESSAGES, "Messages and check-ins", NotificationManager.IMPORTANCE_DEFAULT))
        nm.createNotificationChannel(NotificationChannel(HELP, "Someone needs help", NotificationManager.IMPORTANCE_HIGH))
        MeshEngine.onIncoming = { m -> received(c.applicationContext, m) }
    }

    /** What a group message from someone else says, as an alert. */
    fun alertFor(c: Context, m: Message): Alert {
        val group = MeshEngine.groupName(m.group) ?: Groups.current(c)?.name ?: "your group"
        val me = c.getSharedPreferences("mesh", 0).getString("name", "") ?: ""
        val check = CheckIn.of(m.text); val vouch = Vouch.of(m.text); val ask = AreYouSafe.of(m.text)
        fun details(needs: Set<Need>, people: Int?) = (needs.map { it.label } + listOfNotNull(people?.let { "$it people" })).joinToString(" · ")
        return when {
            check == CheckIn.HELP -> Alert("${m.name} needs help",
                details(CheckIn.needs(m.text), CheckIn.people(m.text)).ifEmpty { "Open DarkProof to see where they are." } + " · $group", m.group, true, false, m.id)
            vouch?.status == CheckIn.HELP -> Alert("${vouch.subject} needs help",
                listOf(details(vouch.needs, vouch.people), "Reported by ${m.name} · $group").filter { it.isNotEmpty() }.joinToString(" · "), m.group, true, false, m.id)
            ask != null && ask.isFor(me) -> Alert(if (ask.to == null) "${m.name} asks: is everyone safe?" else "${m.name} asks: are you safe?",
                "Answer with one tap · $group", m.group, true, true, m.id)
            check == CheckIn.SAFE -> Alert("${m.name} is safe", group, m.group, false, false, m.id)
            vouch != null -> Alert("${vouch.subject} is safe", "Reported by ${m.name} · $group", m.group, false, false, m.id)
            else -> Alert("${m.name} · $group", if (m.photo != null) Photo.text(Photo.caption(m.text)) else m.text, m.group, false, false, m.id)
        }
    }

    private fun received(c: Context, m: Message) {
        if (!Moderation.visible(c, m)) return
        val a = alertFor(c, m)
        if (onScreen) {
            val otherGroup = m.group != null && m.group != Groups.current(c)?.code
            if (a.urgent || otherGroup) { inApp?.invoke(a); if (a.urgent) vibrate(c) }
            return
        }
        if (c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED && Build.VERSION.SDK_INT >= 33) return
        // Help alerts and questions each get their own notification; the rest replace one per person.
        val id = if (a.urgent) m.id.hashCode() else m.sender.hashCode()
        val n = android.app.Notification.Builder(c, if (a.urgent) HELP else MESSAGES)
            .setSmallIcon(R.drawable.ic_notifications).setContentTitle(a.title).setContentText(a.body)
            .setStyle(android.app.Notification.BigTextStyle().bigText(a.body))
            .setContentIntent(open(c, id, m.group)).setAutoCancel(true).setGroup("group")
        if (a.ask) {
            n.addAction(android.app.Notification.Action.Builder(null, "I'm safe", PendingIntent.getBroadcast(c, id,
                Intent(c, AnswerReceiver::class.java).putExtra(Actions.EXTRA_GROUP, m.group).putExtra(AnswerReceiver.NOTIFICATION, id),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)).build())
            n.addAction(android.app.Notification.Action.Builder(null, "I need help", PendingIntent.getActivity(c, id + 1,
                Actions.intent(c, Actions.HELP, m.group).putExtra(AnswerReceiver.NOTIFICATION, id),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)).build())
        }
        c.getSystemService(NotificationManager::class.java).notify(id, n.build())
    }

    /** Opens DarkProof on [group]'s chat. */
    private fun open(c: Context, id: Int, group: String?) = PendingIntent.getActivity(c, id, Actions.intent(c, Actions.CHAT, group),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    @Suppress("DEPRECATION")
    fun vibrate(c: Context) = runCatching {
        val v = if (Build.VERSION.SDK_INT >= 31) c.getSystemService(android.os.VibratorManager::class.java).defaultVibrator
                else c.getSystemService(android.os.Vibrator::class.java)
        v?.vibrate(android.os.VibrationEffect.createWaveform(longArrayOf(0, 350, 150, 350), -1))
    }
}

/** When each saved group's chat was last read, so new messages show as unread (Chat tab, group switcher). */
object ReadMarks {
    private fun prefs(c: Context) = c.getSharedPreferences("read", 0)
    fun lastRead(c: Context, code: String): Long = prefs(c).getLong(key(code), 0L)
    fun markRead(c: Context, code: String, ts: Long) { if (ts > lastRead(c, code)) prefs(c).edit().putLong(key(code), ts).apply() }
    /** Messages from others in [code] newer than the last read one. */
    fun unread(c: Context, all: List<Message>, code: String): Int {
        val since = lastRead(c, code)
        return all.count { !it.public && it.group == code && it.ts > since && it.sender != MeshEngine.deviceId }
    }
    private fun key(code: String) = code.hashCode().toString() // not the code itself
}

/** "Today", "Yesterday", or the date in the phone's language, for the chat. */
fun dayLabel(c: Context, ts: Long, now: Long = System.currentTimeMillis()): String = when {
    android.text.format.DateUtils.isToday(ts) -> "Today"
    android.text.format.DateUtils.isToday(ts + 86_400_000L) -> "Yesterday"
    else -> {
        val sameYear = java.util.Calendar.getInstance().apply { timeInMillis = ts }.get(java.util.Calendar.YEAR) ==
            java.util.Calendar.getInstance().apply { timeInMillis = now }.get(java.util.Calendar.YEAR)
        android.text.format.DateUtils.formatDateTime(c, ts, android.text.format.DateUtils.FORMAT_SHOW_DATE or
            android.text.format.DateUtils.FORMAT_SHOW_WEEKDAY or (if (sameYear) android.text.format.DateUtils.FORMAT_NO_YEAR else android.text.format.DateUtils.FORMAT_SHOW_YEAR))
    }
}

/** The day a message was sent, for grouping the chat by day. */
fun dayOf(ts: Long): Int = java.util.Calendar.getInstance().apply { timeInMillis = ts }.let { it.get(java.util.Calendar.YEAR) * 1000 + it.get(java.util.Calendar.DAY_OF_YEAR) }

/** Formats a day or time for the chat. */
fun fullTime(ts: Long): String = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(ts))

/** How to reach the developer (Settings, "Help and safety"); app stores ask apps with public posts to show this. */
object Contact {
    const val EMAIL = "support@darkproof.app"
    const val MAIL = "mailto:support@darkproof.app?subject=DarkProof%20report"
    const val PRIVACY = "https://darkproof.app/privacy"
    fun open(c: android.content.Context, uri: String) {
        runCatching { c.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(uri))) }
            .onFailure { android.widget.Toast.makeText(c, if (uri.startsWith("mailto")) "Write to $EMAIL" else uri, android.widget.Toast.LENGTH_LONG).show() }
    }
}
