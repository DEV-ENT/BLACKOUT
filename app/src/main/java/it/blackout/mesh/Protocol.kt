package it.blackout.mesh

import java.security.SecureRandom
import java.util.Locale
import kotlin.math.*

// Message conventions on top of the wire format, the same as the iPhone app (spec/FORMAT.md): check-ins with battery,
// position, needs and head count, reports about others, "are you safe?" requests, places, photos, delivery receipts,
// invites and group codes. Plain Kotlin, no Android dependencies, so unit tests run.

/** A position shared in a check-in or a place: decimal degrees, and how sure the phone was (meters). */
data class Spot(val lat: Double, val lon: Double, val accuracy: Int? = null) {
    val isValid get() = lat.isFinite() && lon.isFinite() && lat in -90.0..90.0 && lon in -180.0..180.0

    /** "45.46420,9.19000 ±12m": 5 decimals is about 1 m. */
    val text: String get() {
        val ll = String.format(Locale.ROOT, "%.5f,%.5f", lat, lon)
        return if (accuracy != null && accuracy in 0..99_999) "$ll ±${accuracy}m" else ll
    }

    /** The 10-digit Plus Code of this position, like "8FQFF57R+M2" (about 14 × 14 m), or null if it is not valid. */
    val plusCode: String? get() = if (isValid) PlusCode.encode(lat, lon) else null

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

/** What someone who needs help needs: a small fixed set, written as English words after "🆘 I need help: ". */
enum class Need(val word: String, val label: String) {
    INJURED("injured", "Injured"), TRAPPED("trapped", "Trapped"), WATER("water", "Need water"), FOOD("food", "Need food"),
    MEDICINE("medicine", "Need medicine"), SHELTER("shelter", "Need shelter");

    companion object {
        /** "injured, water", always in this order. */
        fun text(needs: Set<Need>) = entries.filter { it in needs }.joinToString(", ") { it.word }
        /** The needs in "injured, water"; unknown words are skipped, so newer apps can add needs. */
        fun parse(list: String): Set<Need> =
            list.split(",").mapNotNull { w -> entries.firstOrNull { it.word.equals(w.trim(), ignoreCase = true) } }.toSet()
    }
}

/**
 * A check-in is a group message starting with ✅ or 🆘, optionally with what the sender needs, how many people they
 * speak for, battery and position: "🆘 I need help: injured, water · 👥 3 · 🔋 23% · 📍 45.46420,9.19000 ±12m".
 */
enum class CheckIn(val raw: String) {
    SAFE("✅ I'm safe"), HELP("🆘 I need help");

    /** [needs] are written for HELP only; [people] (1–99) for both. */
    fun text(battery: Int?, spot: Spot? = null, needs: Set<Need> = emptySet(), people: Int? = null): String {
        var t = raw
        if (this == HELP && needs.isNotEmpty()) t += ": " + Need.text(needs)
        if (people != null && people in 1..99) t += " · 👥 $people"
        if (battery != null && battery in 0..100) t += " · 🔋 $battery%"
        if (spot != null && spot.isValid) t += " · 📍 " + spot.text
        return t
    }

    companion object {
        fun of(text: String) = when { text.startsWith("✅") -> SAFE; text.startsWith("🆘") -> HELP; else -> null }
        /** The needs a "🆘 I need help: injured, water" check-in lists (empty for anything else). */
        fun needs(text: String): Set<Need> {
            val p = HELP.raw + ": "
            return if (text.startsWith(p)) Need.parse(text.substring(p.length).substringBefore(" · ")) else emptySet()
        }
        /** How many people a check-in speaks for (1–99), from its last "👥 N". */
        fun people(text: String): Int? = if (of(text) != null) peopleIn(text) else null
        internal fun peopleIn(text: String): Int? {
            val i = text.lastIndexOf("👥 ").takeIf { it >= 0 } ?: return null
            val rest = text.substring(i + "👥 ".length)
            val digits = rest.takeWhile { it in '0'..'9' }
            if (digits.isEmpty() || digits.length > 2 || !(rest.length == digits.length || rest[digits.length] == ' ')) return null
            return digits.toInt().takeIf { it in 1..99 }
        }
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

/**
 * A check-in for someone else, sent by whoever has news of them: "👤 Grandma is safe" or
 * "👤 Grandma needs help: injured · 👥 2 · 📍 45.46420,9.19000". It does not start with ✅ or 🆘, so no app (old or new)
 * takes it for the sender's own check-in. The reporter is the message's sender; there is no battery level.
 */
data class Vouch(val subject: String, val status: CheckIn, val needs: Set<Need> = emptySet(), val people: Int? = null, val spot: Spot? = null) {
    val text: String get() {
        var t = PREFIX + cleanName(subject).ifEmpty { "Someone" } + if (status == CheckIn.SAFE) SAFE else HELP
        if (status == CheckIn.HELP && needs.isNotEmpty()) t += ": " + Need.text(needs)
        if (people != null && people in 1..99) t += " · 👥 $people"
        if (spot != null && spot.isValid) t += " · 📍 " + spot.text
        return t
    }

    companion object {
        const val MAX_NAME = 24
        const val PREFIX = "👤 "
        private const val SAFE = " is safe"
        private const val HELP = " needs help"

        fun of(text: String): Vouch? {
            if (!text.startsWith(PREFIX)) return null
            val head = text.substring(PREFIX.length).substringBefore(" · ")
            val subject: String; val status: CheckIn; var needs = emptySet<Need>()
            if (head.endsWith(SAFE)) { subject = head.dropLast(SAFE.length); status = CheckIn.SAFE } else {
                val i = head.lastIndexOf(HELP).takeIf { it >= 0 } ?: return null
                val rest = head.substring(i + HELP.length)
                if (rest.isNotEmpty() && !rest.startsWith(": ")) return null
                subject = head.substring(0, i); status = CheckIn.HELP; needs = Need.parse(rest.removePrefix(": "))
            }
            val name = cleanName(subject).ifEmpty { return null }
            return Vouch(name, status, needs, CheckIn.peopleIn(text), Spot.last(text))
        }

        /** How the People list matches names: case and spacing don't matter ("grandma " is "Grandma"). */
        fun key(name: String) = words(name).lowercase(Locale.ROOT)

        /** One line, no "·" (it separates the parts), at most MAX_NAME characters. */
        internal fun cleanName(s: String): String {
            val t = words(s.replace('·', ' '))
            return if (t.length <= MAX_NAME) t else t.take(MAX_NAME).let { if (it.last().isHighSurrogate()) it.dropLast(1) else it }.trim()
        }

        /** The words of [s] joined by single spaces (any Unicode white space separates words, as on the iPhone). */
        private fun words(s: String): String {
            val sb = StringBuilder(); var space = false
            for (c in s) if (c.isWhitespace()) space = sb.isNotEmpty() else { if (space) sb.append(' '); space = false; sb.append(c) }
            return sb.toString()
        }
    }
}

/** "Are you safe?" asked to the whole group ("❓ Is everyone safe?") or one person ("❓ Marco, are you safe?"). */
data class AreYouSafe(val to: String? = null) {
    val text: String get() = to?.let { Vouch.cleanName(it) }?.takeIf { it.isNotEmpty() }?.let { "❓ $it$SUFFIX" } ?: EVERYONE

    /** Whether someone called [myName] should be offered the one-tap "I'm safe" / "I need help" answers. */
    fun isFor(myName: String) = to == null || Vouch.key(to) == Vouch.key(myName)

    companion object {
        const val EVERYONE = "❓ Is everyone safe?"
        private const val SUFFIX = ", are you safe?"
        fun of(text: String): AreYouSafe? {
            if (text == EVERYONE) return AreYouSafe(null)
            if (!text.startsWith("❓ ") || !text.endsWith(SUFFIX)) return null
            val name = Vouch.cleanName(text.substring(2, text.length - SUFFIX.length)).ifEmpty { return null }
            return AreYouSafe(name)
        }
    }
}

/** What a shared place offers. */
enum class PlaceKind(val raw: String) {
    WATER("💧 Water"), SHELTER("🏠 Shelter"), CHARGING("🔌 Charging"), MEDICAL("🏥 Medical");
    val word get() = raw.substringAfter(" ")
}

/** How current a shared place is (Place.freshness). */
enum class Freshness { FRESH, OLD, EXPIRED }

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
        const val OLD_AFTER_MS = 24 * 3_600_000L
        const val EXPIRED_AFTER_MS = 7 * 24 * 3_600_000L

        /** How current a place shared at [ts] is: older than 24 h is OLD (shown greyed), older than 7 days EXPIRED (hidden). */
        fun freshness(ts: Long, now: Long = System.currentTimeMillis()): Freshness = when {
            now - ts > EXPIRED_AFTER_MS -> Freshness.EXPIRED
            now - ts > OLD_AFTER_MS -> Freshness.OLD
            else -> Freshness.FRESH // including a sender whose clock is ahead
        }

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

/**
 * Someone in the group, known from the messages they sent, or from someone else's report about them (a Vouch). A report
 * has [reportedBy] set, an id starting with [REPORT_ID], and must be shown as "reported by …", never as their own check-in.
 */
data class Person(
    val id: String, val name: String, val lastTs: Long,
    val checkIn: CheckIn? = null, val checkInTs: Long = 0, val battery: Int? = null,
    val spot: Spot? = null, val spotTs: Long = 0,
    /** From the latest check-in: what they need (HELP only) and how many people it speaks for. */
    val needs: Set<Need> = emptySet(), val people: Int? = null,
    /** For a report: who sent it (name and device id). Null for the person's own check-ins. */
    val reportedBy: String? = null, val reporterId: String? = null,
) {
    val isReport get() = reportedBy != null

    companion object {
        /** Ids of report entries: this prefix, then Vouch.key(name). Device ids never look like this. */
        const val REPORT_ID = "report:"

        /**
         * Everyone who wrote in the group (not Public, not the Wi-Fi board), plus the people someone reported on (by
         * name, latest report wins, including reports this phone sent), people asking for help first. A person's own
         * check-in hides reports about them that are not newer (matched by name).
         */
        fun all(messages: List<Message>, me: String): List<Person> {
            val by = LinkedHashMap<String, Person>()
            val reports = LinkedHashMap<String, Person>()
            for (m in messages) {
                if (m.public || m.sender.startsWith("web-")) continue
                Vouch.of(m.text)?.let { v ->
                    val id = REPORT_ID + Vouch.key(v.subject)
                    var p = reports[id] ?: Person(id, v.subject, m.ts)
                    if (m.ts >= p.checkInTs) p = p.copy(name = v.subject, lastTs = maxOf(p.lastTs, m.ts), checkIn = v.status, checkInTs = m.ts,
                        needs = v.needs, people = v.people, reportedBy = m.name, reporterId = m.sender)
                    if (v.spot != null && m.ts >= p.spotTs) p = p.copy(spot = v.spot, spotTs = m.ts)
                    reports[id] = p
                }
                if (m.sender == me) continue
                var p = by[m.sender] ?: Person(m.sender, m.name, m.ts)
                if (m.ts >= p.lastTs) p = p.copy(lastTs = m.ts, name = m.name)
                val c = CheckIn.of(m.text)
                if (c != null && m.ts >= p.checkInTs) p = p.copy(checkIn = c, checkInTs = m.ts, battery = CheckIn.battery(m.text),
                    needs = CheckIn.needs(m.text), people = CheckIn.people(m.text))
                val s = CheckIn.spot(m.text)
                if (s != null && m.ts >= p.spotTs) p = p.copy(spot = s, spotTs = m.ts)
                by[m.sender] = p
            }
            val own = HashMap<String, Long>()
            for (p in by.values) if (p.checkIn != null) own.merge(REPORT_ID + Vouch.key(p.name), p.checkInTs, ::maxOf)
            val shown = reports.values.filter { r -> (own[r.id] ?: Long.MIN_VALUE) < r.checkInTs }
            return (by.values + shown).sortedWith(compareByDescending<Person> { if (it.checkIn == CheckIn.HELP) 1 else 0 }.thenByDescending { it.lastTs })
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
 * with the map link last so messaging apps make it tappable. The position also comes as a Plus Code, which rescuers
 * can type into any map app. Same text as the iPhone (StatusShare.swift).
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
            spot.plusCode?.let { sb.append(" (").append(it).append(')') }
            sb.append(" https://osm.org/?mlat=").append(lat).append("&mlon=").append(lon)
        }
        return sb.toString()
    }
}

/**
 * Group invites (spec/FORMAT.md, "Invites"): darkproof://join?name=<name>&code=<code>, or the same items after
 * https://darkproof.app/join# so the link also works for people who don't have the app yet.
 */
object Invite {
    const val MAX_GROUP_NAME = 24
    const val MIN_CODE_LENGTH = 8
    /** Generated codes: 16 of these, in four groups of four joined by "-". */
    const val SYMBOLS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    const val WEB_PREFIX = "https://darkproof.app/join#"

    /** The app link: opens DarkProof where it is installed (all versions), does nothing elsewhere. */
    fun url(name: String, code: String) = "darkproof://join?" + items(name, code)

    /**
     * The web link, for QR codes and sharing: opens DarkProof where it is installed (once darkproof.app serves the
     * app-link files), else darkproof.app/join, which offers the app link and the downloads. The code stays in the
     * #fragment, which browsers never send to a server.
     */
    fun webUrl(name: String, code: String) = WEB_PREFIX + items(name, code)

    private fun items(name: String, code: String) = "name=${enc(name)}&code=${enc(code)}"
    private val APP_LINK = Regex("^(?i:darkproof)://(?i:join)\\?(.*)$")
    private val WEB_LINK = Regex("^(?i:https?)://(?i:(?:www\\.)?darkproof\\.app)/(?i:join)(?:/|\\.html)?(?:\\?[^#]*)?#(.*)$")
    private val GENERATED = Regex("^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}$")
    /** Ignored when reading a typed code: spaces, tabs, line breaks, "-", "_" and other dashes. */
    private const val SEPARATORS = "  \t\n\r-_‐‑‒–—―−"

    /** Group name and code in an invite link (either form), or null if it is not one. */
    fun parse(link: String): Pair<String, String>? {
        val s = link.trim()
        val items = (APP_LINK.find(s) ?: WEB_LINK.find(s))?.groupValues?.get(1) ?: return null
        val q = LinkedHashMap<String, String>()
        for (kv in items.split("&")) {
            val i = kv.indexOf('='); if (i >= 0) q.putIfAbsent(dec(kv.substring(0, i)), dec(kv.substring(i + 1)))
        }
        val code = q["code"]?.trim()?.takeIf { it.length >= MIN_CODE_LENGTH } ?: return null
        val name = q["name"]?.trim().orEmpty().ifEmpty { "Group" }.take(MAX_GROUP_NAME)
        return name to code
    }

    /**
     * The group code someone typed or pasted, cleaned up: the code of an invite link; a generated code typed in lower
     * case, without dashes or with spaces becomes "K7QF-2M9X-PA4T-W8RJ"; anything else is a custom code, only trimmed.
     * Use it on new input only, never on saved groups (a custom code that happens to look generated would change).
     */
    fun normalizeCode(input: String): String {
        parse(input)?.let { return it.second }
        val s = input.trim()
        val bare = s.filter { it !in SEPARATORS }.map { if (it in 'a'..'z') it - 32 else it }.joinToString("")
        return if (bare.length == 16 && bare.all { it in SYMBOLS }) bare.chunked(4).joinToString("-") else s
    }

    /** Whether a code has the generated form (80 bits). Custom codes, especially short ones, can be guessed. */
    fun isGeneratedCode(code: String) = GENERATED.matches(code)

    /** A random code like "K7QF-2M9X-PA4T-W8RJ": 80 bits, no 0/O or 1/I. */
    fun newCode(): String {
        val b = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return b.map { SYMBOLS[(it.toInt() and 0xFF) % 32] }.chunked(4).joinToString("-") { it.joinToString("") }
    }

    /** Percent-encodes everything but RFC 3986 unreserved characters (the iPhone writes the same bytes). */
    private fun enc(s: String) = buildString {
        for (byte in s.toByteArray(Charsets.UTF_8)) {
            val c = (byte.toInt() and 0xFF)
            if (c.toChar().let { it.isLetterOrDigit() && c < 128 } || c.toChar() in "-._~") append(c.toChar())
            else append('%').append(String.format(Locale.ROOT, "%02X", c))
        }
    }
    private fun dec(s: String): String = try { java.net.URLDecoder.decode(s.replace("+", "%2B"), "UTF-8") } catch (_: Exception) { s }
}
