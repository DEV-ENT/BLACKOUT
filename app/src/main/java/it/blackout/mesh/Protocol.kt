package it.blackout.mesh

import java.security.SecureRandom
import java.util.Locale
import kotlin.math.*

// Message conventions on top of the wire format, the same as the iPhone app (spec/FORMAT.md): check-ins with battery
// and position, places, photos, delivery receipts and invites. Plain Kotlin, no Android dependencies, so unit tests run.

/** A position shared in a check-in or a place: decimal degrees, and how sure the phone was (meters). */
data class Spot(val lat: Double, val lon: Double, val accuracy: Int? = null) {
    val isValid get() = lat.isFinite() && lon.isFinite() && lat in -90.0..90.0 && lon in -180.0..180.0

    /** "45.46420,9.19000 ±12m": 5 decimals is about 1 m. */
    val text: String get() {
        val ll = String.format(Locale.ROOT, "%.5f,%.5f", lat, lon)
        return if (accuracy != null && accuracy in 0..99_999) "$ll ±${accuracy}m" else ll
    }

    companion object {
        /** The last " 📍 LAT,LON ±Nm" in a text, or null if there is none or it is malformed. */
        fun last(text: String): Spot? {
            val i = text.lastIndexOf("📍 ").takeIf { it >= 0 } ?: return null
            val words = text.substring(i + "📍 ".length).split(" ")
            val ll = words.first().split(",")
            fun num(s: String) = if (s.length <= 12 && s.all { it in '0'..'9' || it == '.' || it == '-' }) s.toDoubleOrNull() else null
            if (ll.size != 2) return null
            val lat = num(ll[0]) ?: return null; val lon = num(ll[1]) ?: return null
            var acc: Int? = null
            if (words.size > 1 && words[1].startsWith("±") && words[1].endsWith("m")) {
                val d = words[1].drop(1).dropLast(1)
                if (d.length in 1..5 && d.all { it in '0'..'9' }) acc = d.toInt()
            }
            return Spot(lat, lon, acc).takeIf { it.isValid }
        }
    }
}

/** Distance and direction on the Earth (spherical model). */
object Geo {
    private const val R = 6_371_008.8
    fun distance(a: Spot, b: Spot): Double {
        val p1 = Math.toRadians(a.lat); val p2 = Math.toRadians(b.lat)
        val dp = Math.toRadians(b.lat - a.lat); val dl = Math.toRadians(b.lon - a.lon)
        val h = sin(dp / 2).pow(2) + cos(p1) * cos(p2) * sin(dl / 2).pow(2)
        return 2 * R * asin(min(1.0, sqrt(h)))
    }
    /** Degrees clockwise from true north, 0 until 360. */
    fun bearing(a: Spot, b: Spot): Double {
        val p1 = Math.toRadians(a.lat); val p2 = Math.toRadians(b.lat); val dl = Math.toRadians(b.lon - a.lon)
        val d = Math.toDegrees(atan2(sin(dl) * cos(p2), cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)))
        return (d + 360) % 360
    }
    fun compassWord(bearing: Double): String {
        val words = listOf("North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest")
        return words[(((bearing % 360 + 360) % 360 + 22.5) / 45).toInt() % 8]
    }
    /** "40 m", "250 m", "1.2 km", "12 km". */
    fun meters(d: Double): String = when {
        d < 100 -> "${((d / 5).roundToInt() * 5)} m"
        d < 1000 -> "${((d / 10).roundToInt() * 10)} m"
        d < 10_000 -> String.format(Locale.ROOT, "%.1f km", d / 1000)
        else -> "${(d / 1000).roundToInt()} km"
    }
}

/** A check-in is a group message starting with ✅ or 🆘, optionally with battery and position. */
enum class CheckIn(val raw: String) {
    SAFE("✅ I'm safe"), HELP("🆘 I need help");

    fun text(battery: Int?, spot: Spot? = null): String {
        var t = raw
        if (battery != null && battery in 0..100) t += " · 🔋 $battery%"
        if (spot != null && spot.isValid) t += " · 📍 " + spot.text
        return t
    }

    companion object {
        fun of(text: String) = when { text.startsWith("✅") -> SAFE; text.startsWith("🆘") -> HELP; else -> null }
        fun battery(text: String): Int? {
            if (of(text) == null) return null
            val i = text.lastIndexOf("🔋 ").takeIf { it >= 0 } ?: return null
            val rest = text.substring(i + "🔋 ".length)
            val digits = rest.takeWhile { it in '0'..'9' }
            if (digits.isEmpty() || digits.length > 3 || !rest.drop(digits.length).startsWith("%")) return null
            return digits.toInt().takeIf { it <= 100 }
        }
        fun spot(text: String): Spot? = if (of(text) != null) Spot.last(text) else null
    }
}

/** What a shared place offers. */
enum class PlaceKind(val raw: String) {
    WATER("💧 Water"), SHELTER("🏠 Shelter"), CHARGING("🔌 Charging"), MEDICAL("🏥 Medical");
    val word get() = raw.substringAfter(" ")
}

/** A place someone shared on the Public channel: "💧 Water: note · 📍 45.46420,9.19000 ±12m". */
data class Place(val kind: PlaceKind, val note: String, val spot: Spot?) {
    val text: String get() {
        var n = note.trim()
        if (n.length > MAX_NOTE) n = n.take(MAX_NOTE).let { if (it.last().isHighSurrogate()) it.dropLast(1) else it }
        var t = if (n.isEmpty()) kind.raw else "${kind.raw}: $n"
        if (spot != null && spot.isValid) t += " · 📍 " + spot.text
        return t
    }

    companion object {
        const val MAX_NOTE = 200
        fun of(text: String): Place? {
            val kind = PlaceKind.entries.firstOrNull { text.startsWith(it.raw) } ?: return null
            var rest = text.substring(kind.raw.length)
            if (!(rest.isEmpty() || rest.startsWith(":") || rest.startsWith(" · "))) return null // "💧 Waterfall" is not one
            val spot = Spot.last(text)
            if (spot != null) rest.lastIndexOf(" · 📍 ").takeIf { it >= 0 }?.let { rest = rest.substring(0, it) }
            if (rest.startsWith(":")) rest = rest.drop(1)
            return Place(kind, rest.trim(' '), spot)
        }
    }
}

/** Photos ride in a 4th plaintext field that older readers skip. */
object Photo {
    const val JPEG: Byte = 0x01
    const val MAX_BYTES = 14_000
    const val PLACEHOLDER = "📷 Photo"
    fun text(caption: String) = caption.trim().let { if (it.isEmpty()) PLACEHOLDER else "📷 $it" }
    fun caption(text: String) = if (text == PLACEHOLDER) "" else text.removePrefix("📷 ")
}

/** Delivery receipts: the ids of confirmed messages, separated by spaces, at most 200 per receipt. */
object Receipt {
    const val MAX_IDS = 200
    fun text(ids: List<String>) = ids.joinToString(" ")
    fun ids(text: String) = text.split(" ").filter { id -> id.length == 16 && id.all { it in '0'..'9' || it in 'a'..'f' } }
    fun batches(ids: List<String>) = ids.chunked(MAX_IDS)
}

/** Someone who confirmed getting a message. */
data class Reader(val id: String, val name: String, val ts: Long)

/** Who got which message, built from opened receipts. */
class Deliveries {
    private val byMessage = HashMap<String, MutableList<Reader>>()
    /** A copy: receipts keep arriving on other threads while the screen reads it. */
    fun readers(messageId: String): List<Reader> = byMessage[messageId]?.toList().orEmpty()
    fun add(r: Message) {
        for (id in Receipt.ids(r.text)) {
            val list = byMessage.getOrPut(id) { mutableListOf() }
            val i = list.indexOfFirst { it.id == r.sender }
            if (i >= 0) list[i] = Reader(r.sender, r.name, min(list[i].ts, r.ts)) else list += Reader(r.sender, r.name, r.ts)
            list.sortBy { it.ts }
        }
    }
}

/** Someone in the group, known from the messages they sent. */
data class Person(
    val id: String, val name: String, val lastTs: Long,
    val checkIn: CheckIn? = null, val checkInTs: Long = 0, val battery: Int? = null,
    val spot: Spot? = null, val spotTs: Long = 0,
) {
    companion object {
        /** Everyone who wrote in the group (not Public, not the Wi-Fi board), people asking for help first. */
        fun all(messages: List<Message>, me: String): List<Person> {
            val by = LinkedHashMap<String, Person>()
            for (m in messages) {
                if (m.public || m.sender == me || m.sender.startsWith("web-")) continue
                var p = by[m.sender] ?: Person(m.sender, m.name, m.ts)
                if (m.ts >= p.lastTs) p = p.copy(lastTs = m.ts, name = m.name)
                val c = CheckIn.of(m.text)
                if (c != null && m.ts >= p.checkInTs) p = p.copy(checkIn = c, checkInTs = m.ts, battery = CheckIn.battery(m.text))
                val s = CheckIn.spot(m.text)
                if (s != null && m.ts >= p.spotTs) p = p.copy(spot = s, spotTs = m.ts)
                by[m.sender] = p
            }
            return by.values.sortedWith(compareByDescending<Person> { if (it.checkIn == CheckIn.HELP) 1 else 0 }.thenByDescending { it.lastTs })
        }
    }
}

/**
 * What the on-device AI sees, sized for its 4,096-token window (about 4 characters per token): the group summary, then
 * the newest turns that fit, starting with a question. That leaves room for the instructions, the question and a
 * 1,024-token answer.
 */
object AiContext {
    const val MAX_HISTORY_CHARS = 4_000
    const val MAX_SITUATION_CHARS = 4_000
    const val MAX_TURNS = 12

    fun <T> fit(turns: List<T>, text: (T) -> String, isQuestion: (T) -> Boolean,
                maxChars: Int = MAX_HISTORY_CHARS, maxTurns: Int = MAX_TURNS): List<T> {
        val out = ArrayDeque<T>(); var total = 0
        for (t in turns.asReversed()) {
            val n = text(t).length
            if (out.size >= maxTurns || total + n > maxChars) break
            out.addFirst(t); total += n
        }
        while (out.isNotEmpty() && !isQuestion(out.first())) out.removeFirst()
        return out.toList()
    }
}

/**
 * A check-in as plain text for other apps: satellite messengers, text messages once the network is back, anything.
 * It leaves DarkProof unencrypted. Kept under 160 characters, the limit of satellite messengers such as Garmin inReach,
 * with the map link last so messaging apps make it tappable. Same text as the iPhone (StatusShare.swift).
 */
object StatusShare {
    fun text(c: CheckIn, name: String, battery: Int?, spot: Spot?): String {
        val sb = StringBuilder(c.raw)
        name.trim().take(24).takeIf { it.isNotEmpty() }?.let { sb.append(" — ").append(it) }
        sb.append('.')
        if (battery != null && battery in 0..100) sb.append(" Battery ").append(battery).append("%.")
        if (spot != null && spot.isValid) {
            val lat = String.format(Locale.ROOT, "%.5f", spot.lat); val lon = String.format(Locale.ROOT, "%.5f", spot.lon)
            sb.append(' ').append(lat).append(", ").append(lon)
            spot.accuracy?.takeIf { it in 0..99_999 }?.let { sb.append(" ±").append(it).append(" m") }
            sb.append(" https://osm.org/?mlat=").append(lat).append("&mlon=").append(lon)
        }
        return sb.toString()
    }
}

/** Group invites: darkproof://join?name=<name>&code=<code>. */
object Invite {
    const val MAX_GROUP_NAME = 24
    private const val SYMBOLS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    fun url(name: String, code: String) = "darkproof://join?name=${enc(name)}&code=${enc(code)}"

    /** Group name and code in an invite link, or null if it is not one. */
    fun parse(link: String): Pair<String, String>? {
        val m = Regex("^(?i:darkproof)://(?i:join)\\?(.*)$").find(link.trim()) ?: return null
        val q = m.groupValues[1].split("&").mapNotNull { kv ->
            val i = kv.indexOf('='); if (i < 0) null else dec(kv.substring(0, i)) to dec(kv.substring(i + 1))
        }.toMap()
        val code = q["code"]?.trim()?.takeIf { it.length >= 8 } ?: return null
        val name = q["name"]?.trim().orEmpty().ifEmpty { "Group" }.take(MAX_GROUP_NAME)
        return name to code
    }

    /** A random code like "K7QF-2M9X-PA4T-W8RJ": 80 bits, no 0/O or 1/I. */
    fun newCode(): String {
        val b = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return b.map { SYMBOLS[(it.toInt() and 0xFF) % 32] }.chunked(4).joinToString("-") { it.joinToString("") }
    }

    /** Percent-encodes everything but RFC 3986 unreserved characters, as URLComponents does for these values. */
    private fun enc(s: String) = buildString {
        for (byte in s.toByteArray(Charsets.UTF_8)) {
            val c = (byte.toInt() and 0xFF)
            if (c.toChar().let { it.isLetterOrDigit() && c < 128 } || c.toChar() in "-._~") append(c.toChar())
            else append('%').append(String.format(Locale.ROOT, "%02X", c))
        }
    }
    private fun dec(s: String): String = try { java.net.URLDecoder.decode(s.replace("+", "%2B"), "UTF-8") } catch (_: Exception) { s }
}
