package it.blackout.mesh

import org.junit.Assert.*
import org.junit.Test

// The same values as the iPhone's tests (ios/BlackoutCore/Tests), so both apps agree byte for byte.
class ProtocolTest {
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private val duomo = Spot(45.46420, 9.19000, 12)
    private val group = GroupCrypto("test-group-1")

    @Test fun receiptKeyVector() {
        val key = GroupCrypto.deriveKey("test-group-1")
        assertEquals("5b3b419c3127c6562d34f9357179690746274ea9f6088385901e83d1d4055a9a", hex(key))
        assertEquals("496bfa142c33041abecd0fdb71763051e81c2fed0a55cbc1c0a7af8311d4a225", hex(GroupCrypto.deriveReceiptKey(key)))
    }

    @Test fun receiptsOnlyOpenWithTheReceiptKey() {
        val receipts = group.receipts()
        val r = Packet("00000000000000aa", 1_000, 16, receipts.seal("00000000000000aa", 1_000, "dev-b", "Bob", "0123456789abcdef"))
        assertNull(group.open(r))
        assertNull(GroupCrypto(GroupCrypto.PUBLIC_CODE).open(r))
        assertEquals("0123456789abcdef", receipts.open(r)?.text)
        val m = Packet("00000000000000bb", 1_000, 16, group.seal("00000000000000bb", 1_000, "dev-a", "Ann", "hi"))
        assertNull(receipts.open(m))
        assertNull(GroupCrypto("other-group-9").receipts().open(r))
    }

    @Test fun receiptIds() {
        val ids = listOf("0123456789abcdef", "fedcba9876543210")
        assertEquals(ids, Receipt.ids(Receipt.text(ids)))
        assertEquals(listOf("fedcba9876543210"), Receipt.ids("0123456789ABCDEF short 0123456789abcdeg  fedcba9876543210"))
        val many = (0 until 450).map { "%016x".format(it) }
        assertEquals(listOf(200, 200, 50), Receipt.batches(many).map { it.size })
        assertEquals(many, Receipt.batches(many).flatten())
        assertTrue(Receipt.batches(emptyList()).isEmpty())
    }

    @Test fun deliveries() {
        fun r(sender: String, name: String, ts: Long, ids: List<String>) = Message("r$sender$ts", ts, sender, name, Receipt.text(ids))
        val a = "000000000000000a"; val b = "000000000000000b"
        val d = Deliveries()
        listOf(r("lucia", "Lucia", 300, listOf(a)), r("marco", "Marco", 200, listOf(a, b)), r("marco", "Marco R.", 100, listOf(a))).forEach(d::add)
        assertEquals(listOf("marco", "lucia"), d.readers(a).map { it.id })
        assertEquals(100L, d.readers(a).first().ts)
        assertEquals("Marco R.", d.readers(a).first().name)
        assertEquals(listOf("Marco"), d.readers(b).map { it.name })
        assertTrue(d.readers("000000000000000c").isEmpty())
    }

    @Test fun checkInCarriesBatteryAndPosition() {
        val t = CheckIn.SAFE.text(23, duomo)
        assertEquals("✅ I'm safe · 🔋 23% · 📍 45.46420,9.19000 ±12m", t)
        assertEquals(CheckIn.SAFE, CheckIn.of(t))
        assertEquals(23, CheckIn.battery(t))
        assertEquals(duomo, CheckIn.spot(t))
        val noBattery = CheckIn.HELP.text(null, Spot(-33.8688, 151.2093))
        assertEquals("🆘 I need help · 📍 -33.86880,151.20930", noBattery)
        assertEquals(Spot(-33.8688, 151.2093), CheckIn.spot(noBattery))
        assertEquals(CheckIn.SAFE.raw, CheckIn.SAFE.text(null, null))
        assertEquals("✅ I'm safe · 🔋 100%", CheckIn.SAFE.text(100))
        assertNull(CheckIn.battery("✅ I'm safe · 🔋 101%"))
        assertNull(CheckIn.battery("Phone at 🔋 50%")) // not a check-in
    }

    @Test fun badPositionsAreIgnored() {
        assertNull(CheckIn.spot(CheckIn.SAFE.raw))
        assertNull(CheckIn.spot("Meet at 📍 45.46420,9.19000"))
        assertNull(CheckIn.spot("✅ I'm safe · 📍 91.00000,9.19000"))
        assertNull(CheckIn.spot("✅ I'm safe · 📍 45.4,181.0"))
        assertNull(CheckIn.spot("✅ I'm safe · 📍 near the school"))
        assertNull(CheckIn.spot("✅ I'm safe · 📍 45.46420;9.19000"))
        assertNull(CheckIn.spot("✅ I'm safe · 📍 1e2,9"))
        assertEquals(Spot(45.4642, 9.19), CheckIn.spot("✅ I'm safe · 📍 45.46420,9.19000 ±lots"))
        assertEquals(CheckIn.SAFE.raw, CheckIn.SAFE.text(null, Spot(95.0, 0.0)))
    }

    @Test fun distanceAndBearing() {
        val equator = Spot(0.0, 0.0)
        assertEquals(111_195.08, Geo.distance(equator, Spot(1.0, 0.0)), 0.05)
        assertEquals(0.0, Geo.bearing(equator, Spot(1.0, 0.0)), 0.001)
        assertEquals(90.0, Geo.bearing(equator, Spot(0.0, 1.0)), 0.001)
        assertEquals(180.0, Geo.bearing(equator, Spot(-1.0, 0.0)), 0.001)
        assertEquals(270.0, Geo.bearing(equator, Spot(0.0, -1.0)), 0.001)
        val marco = Spot(45.46600, 9.19200)
        assertEquals(253.75, Geo.distance(duomo, marco), 0.01)
        assertEquals(37.93, Geo.bearing(duomo, marco), 0.01)
        assertEquals(0.0, Geo.distance(duomo, duomo), 0.0)
        assertEquals("Northeast", Geo.compassWord(37.93))
        assertEquals("North", Geo.compassWord(359.0))
        assertEquals("West", Geo.compassWord(-90.0))
    }

    @Test fun personKeepsLastKnownPositionAndHelpComesFirst() {
        fun m(sender: String, ts: Long, text: String) = Message("$sender$ts", ts, sender, sender.uppercase(), text)
        val people = Person.all(listOf(
            m("a", 100, CheckIn.SAFE.text(50, duomo)),
            m("a", 200, CheckIn.SAFE.text(40)),
            m("b", 50, CheckIn.HELP.text(9)),
            m("me", 300, "hi"), m("web-1", 300, "board"),
            Message("p1", 400, "c", "C", "public", public = true),
        ), "me")
        assertEquals(listOf("b", "a"), people.map { it.id })
        val a = people[1]
        assertEquals(duomo, a.spot); assertEquals(100L, a.spotTs); assertEquals(40, a.battery); assertEquals(200L, a.lastTs)
    }

    @Test fun places() {
        val p = Place(PlaceKind.WATER, "Tap at the school gym, bring bottles", duomo)
        assertEquals("💧 Water: Tap at the school gym, bring bottles · 📍 45.46420,9.19000 ±12m", p.text)
        assertEquals(p, Place.of(p.text))
        for (kind in PlaceKind.entries) Place(kind, "", null).let { assertEquals(it, Place.of(it.text)) }
        assertEquals("Medical", PlaceKind.MEDICAL.word)
        assertEquals(Place(PlaceKind.CHARGING, "generator at the church", null), Place.of("🔌 Charging: generator at the church"))
        assertEquals(Place(PlaceKind.SHELTER, "", Spot(45.4642, 9.19)), Place.of("🏠 Shelter · 📍 45.46420,9.19000"))
        assertEquals("🏥 Medical", Place(PlaceKind.MEDICAL, "   ", null).text)
        assertNull(Place.of("Water at Via Roma 12")); assertNull(Place.of("💧 Waterfall nearby"))
        assertNull(Place.of(CheckIn.SAFE.raw)); assertNull(Place.of(""))
        assertEquals(Place.MAX_NOTE, Place.of(Place(PlaceKind.WATER, "a".repeat(300), null).text)?.note?.length)
        assertNull(Place.of("💧 Water: here · 📍 somewhere")?.spot)
        assertEquals("here · 📍 somewhere", Place.of("💧 Water: here · 📍 somewhere")?.note)
        assertNull(CheckIn.spot(Place(PlaceKind.WATER, "", duomo).text))
    }

    private val jpeg = byteArrayOf(-1, -40, -1, -32) + ByteArray(9_000) { (it % 251).toByte() } + byteArrayOf(-1, -39)

    @Test fun photoRoundTrip() {
        val c = group.seal("00000000000000aa", 5, "dev-a", "Ann", Photo.text("Bridge is out"), jpeg)
        val m = group.open(Packet("00000000000000aa", 5, 16, c))!!
        assertArrayEquals(jpeg, m.photo)
        assertEquals("📷 Bridge is out", m.text)
        assertEquals("Bridge is out", Photo.caption(m.text))
        assertNull(group.open(Packet("00000000000000bb", 5, 16, group.seal("00000000000000bb", 5, "dev-a", "Ann", "hi")))!!.photo)
    }

    /** Older readers parse three fields and stop; with the same IV the message without a photo is a prefix of the one with it. */
    @Test fun olderReadersSeeTheSameThreeFields() {
        val iv = ByteArray(12) { 7 }
        val without = group.seal("00000000000000cc", 9, "dev-a", "Ann", Photo.PLACEHOLDER, iv = iv)
        val with = group.seal("00000000000000cc", 9, "dev-a", "Ann", Photo.PLACEHOLDER, jpeg, iv)
        val body = without.size - 16
        assertArrayEquals(without.copyOf(body), with.copyOf(body))
        assertTrue(with.size > without.size + jpeg.size)
    }

    @Test fun photoLimits() {
        assertThrows(IllegalArgumentException::class.java) { group.seal("00000000000000dd", 1, "d", "n", "t", ByteArray(Photo.MAX_BYTES + 1)) }
        val c = group.seal("00000000000000ee", 1, "7c0d995b-2c4", "🙂".repeat(20), Photo.text("🙂".repeat(200)), ByteArray(Photo.MAX_BYTES))
        assertTrue(c.size <= Packet.MAX_CIPHER)
        assertNotNull(Packet.decode(Packet("00000000000000ee", 1, 16, c).encode()))
        assertEquals("📷 Photo", Photo.text("  ")); assertEquals("", Photo.caption("📷 Photo")); assertEquals("Water here", Photo.caption("📷 Water here"))
    }

    @Test fun invites() {
        val url = Invite.url("Casa di Nonna & co", "K7QF-2M9X-PA4T-W8RJ")
        assertTrue(url.startsWith("darkproof://join?"))
        assertEquals("Casa di Nonna & co" to "K7QF-2M9X-PA4T-W8RJ", Invite.parse(url))
        val code = "our secret+code=1&2 ünïcode"
        assertEquals(code, Invite.parse(Invite.url("G", code))?.second)
        assertNull(Invite.parse("https://join?code=ABCDEFGHJK"))
        assertNull(Invite.parse("darkproof://other?code=ABCDEFGHJK"))
        assertNull(Invite.parse("darkproof://join?code=short"))
        assertNull(Invite.parse("darkproof://join?name=x"))
        assertEquals("Group", Invite.parse("darkproof://join?code=ABCDEFGHJK")?.first)
        assertEquals(Invite.MAX_GROUP_NAME, Invite.parse(Invite.url("x".repeat(60), "ABCDEFGHJK"))?.first?.length)
        // A link made by the iPhone (URLComponents leaves spaces as %20 and keeps + literal).
        assertEquals("Casa di Nonna" to "abc+def ghi", Invite.parse("darkproof://join?name=Casa%20di%20Nonna&code=abc+def%20ghi"))
        val codes = (0 until 200).map { Invite.newCode() }
        codes.forEach { assertTrue(it, Regex("^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}$").matches(it)) }
        assertEquals(200, codes.toSet().size)
    }

    @Test fun deliveredListIsACopy() {
        val d = Deliveries(); val a = "000000000000000a"
        d.add(Message("r1", 100, "lucia", "Lucia", Receipt.text(listOf(a))))
        val shown = d.readers(a)
        d.add(Message("r2", 200, "marco", "Marco", Receipt.text(listOf(a)))) // arrives while the screen reads `shown`
        assertEquals(1, shown.size); assertEquals(2, d.readers(a).size)
    }

    @Test fun aiContextFitsTheWindow() {
        data class T(val user: Boolean, val text: String)
        val turns = (1..20).flatMap { listOf(T(true, "q$it"), T(false, "a".repeat(300))) }
        val fit = AiContext.fit(turns, { it.text }, { it.user })
        assertTrue(fit.size <= AiContext.MAX_TURNS)
        assertTrue(fit.sumOf { it.text.length } <= AiContext.MAX_HISTORY_CHARS)
        assertTrue(fit.first().user)                                  // starts with a question
        assertEquals(turns.last(), fit.last())                         // keeps the newest
        val huge = listOf(T(true, "q"), T(false, "x".repeat(10_000)))  // one answer bigger than the window
        assertTrue(AiContext.fit(huge, { it.text }, { it.user }).isEmpty())
        assertTrue(AiContext.fit(emptyList<T>(), { it.text }, { it.user }).isEmpty())
    }

    @Test fun statusShareText() {
        val t = StatusShare.text(CheckIn.HELP, "Anna", 64, Spot(45.46420, 9.19000, 12))
        assertEquals("🆘 I need help — Anna. Battery 64%. 45.46420, 9.19000 ±12 m (8FQFF57R+M2) https://osm.org/?mlat=45.46420&mlon=9.19000", t)
        assertTrue(t.length <= 160)
        assertEquals("✅ I'm safe.", StatusShare.text(CheckIn.SAFE, " ", null, null))
        assertEquals("✅ I'm safe — Ben. -33.86880, 151.20930 (4RRH46J5+FP) https://osm.org/?mlat=-33.86880&mlon=151.20930",
            StatusShare.text(CheckIn.SAFE, "Ben", 101, Spot(-33.8688, 151.2093)))
        assertTrue(StatusShare.text(CheckIn.HELP, "x".repeat(60), 100, Spot(-89.99999, -179.99999, 99_999)).length <= 160)
    }

    /** Same values as the iPhone (and Python, see spec/FORMAT.md "Mailboxes"). */
    @Test fun mailboxes() {
        assertEquals(0xa8d0, GroupCrypto("test-group-1").mailbox)
        assertEquals(0x0794, GroupCrypto(GroupCrypto.PUBLIC_CODE).mailbox)
        assertEquals(0xa8d0, GroupCrypto("test-group-1").receipts().mailbox) // receipts go to the group's mailbox
        val id = Packet.newId(0xa8d0)
        assertTrue(id.matches(Regex("^a8d0[0-9a-f]{12}$"))); assertEquals(0xa8d0, Packet.mailbox(id))
        assertNotEquals(Packet.newId(0xa8d0), Packet.newId(0xa8d0))
        assertEquals("0794", Packet.newId(0x0794).take(4))
    }
}
