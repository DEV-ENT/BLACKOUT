package it.blackout.mesh

import org.junit.Assert.*
import org.junit.Test

private const val M1 = "00000000000000a1"

class CoreTest {
    class Net {
        val nodes = HashMap<String, MeshRouter>(); val got = HashMap<String, MutableList<String>>(); val q = ArrayDeque<Triple<String, String, Packet>>()
        fun add(n: String) { got[n] = mutableListOf(); nodes[n] = MeshRouter({ peer, p -> q.add(Triple(n, peer, p)) }, { got[n]!! += it.id }) }
        fun link(a: String, b: String) { nodes[a]!!.peerUp(b); nodes[b]!!.peerUp(a); pump() }
        fun cut(a: String, b: String) { nodes[a]!!.peerDown(b); nodes[b]!!.peerDown(a) }
        fun pump() { while (q.isNotEmpty()) { val (f, t, p) = q.removeFirst(); nodes[t]!!.receive(f, Packet.decode(p.encode())!!) } }
    }
    private fun pkt(id: String, ttl: Int = 16) = Packet(id, System.currentTimeMillis(), ttl, byteArrayOf(1))

    @Test fun multiHopChainDeliversOnce() {
        val n = Net(); listOf("a", "b", "c", "d").forEach(n::add); n.link("a", "b"); n.link("b", "c"); n.link("c", "d"); n.link("d", "a")
        n.nodes["a"]!!.publish(pkt(M1)); n.pump()
        assertEquals(listOf(M1), n.got["c"]); assertEquals(listOf(M1), n.got["b"]); assertEquals(listOf(M1), n.got["d"]); assertTrue(n.got["a"]!!.isEmpty())
    }
    @Test fun storedMessageCrossesWhenCarrierMoves() {
        val n = Net(); listOf("a", "b", "c").forEach(n::add); n.link("a", "b")
        n.nodes["a"]!!.publish(pkt(M1)); n.pump(); n.cut("a", "b"); n.link("b", "c")
        assertEquals(listOf(M1), n.got["c"])
    }
    @Test fun ttlStopsPacket() {
        val n = Net(); listOf("a", "b", "c").forEach(n::add); n.link("a", "b"); n.link("b", "c")
        n.nodes["a"]!!.publish(pkt(M1, 2)); n.pump()
        assertEquals(listOf(M1), n.got["b"]); assertTrue(n.got["c"]!!.isEmpty())
    }
    @Test fun cryptoRoundTripAndWrongCodeAndTamper() {
        val c = GroupCrypto("group-code"); val p = Packet(M1, 5, 16, c.seal(M1, 5, "s", "Max", "hello"))
        assertEquals("hello", c.open(Packet.decode(p.encode())!!)!!.text)
        assertNull(GroupCrypto("other-code").open(p))
        assertNull(c.open(Packet(M1, 6, 16, p.cipher)))
        assertNotNull(c.open(p.withTtl(3)))
    }
    @Test fun garbageRejected() { assertNull(Packet.decode(byteArrayOf(0, 1, 2))) }

    @Test fun loraFrameRoundTrip() {
        val p = Packet(M1, 7, 16, ByteArray(100) { 9 })
        val frame = Meshtastic.toRadioPacket(p.encode(), 0x01020304)
        val data = frame.let { Meshtastic.fieldBytes(it, 1)!! }.let { Meshtastic.fieldBytes(it, 4)!! }
        assertEquals(p.id, Packet.decode(Meshtastic.fieldBytes(data, 2)!!)!!.id)
        // FromRadio.packet (field 2) carries the same MeshPacket
        val from = byteArrayOf(0x12) + Meshtastic.varint(Meshtastic.fieldBytes(frame, 1)!!.size.toLong()) + Meshtastic.fieldBytes(frame, 1)!!
        assertEquals(p.id, Packet.decode(Meshtastic.parseFromRadio(from).payload!!)!!.id)
    }
    @Test fun configCompleteAndOtherPortsParsed() {
        assertEquals(42L, Meshtastic.parseFromRadio(byteArrayOf(0x38, 42)).configComplete)
        val data = byteArrayOf(0x08, 0x01, 0x12, 0x01, 0x41) // TEXT_MESSAGE_APP
        val pkt = byteArrayOf(0x22, data.size.toByte()) + data
        assertNull(Meshtastic.parseFromRadio(byteArrayOf(0x12, pkt.size.toByte()) + pkt).payload)
    }
    @Test fun wantConfigBytes() { assertArrayEquals(byteArrayOf(0x18, 42), Meshtastic.wantConfig(42)) }
    @Test fun loraMessageFitsAtLimit() {
        val c = GroupCrypto("group-code"); val id = Packet.newId()
        val p = Packet(id, 1, 16, c.seal(id, 1, "abcdef012345", "Massimiliano Rossi", "x".repeat(140)))
        assertTrue(p.encode().size.toString(), Meshtastic.fits(p))
        val q = Packet(id, 1, 16, c.seal(id, 1, "abcdef012345", "Massimiliano Rossi", "x".repeat(400)))
        assertFalse(Meshtastic.fits(q))
    }
    @Test fun queuePacesDropsOldAndOversize() {
        var t = 1_000_000_000L; val q = LoraQueue({ t })
        q.offer(Packet(M1, t, 16, ByteArray(10))); q.offer(Packet(M1, t, 15, ByteArray(10)))
        q.offer(Packet("00000000000000a2", t - LoraQueue.MAX_AGE_MS - 1, 16, ByteArray(10)))
        q.offer(Packet("00000000000000a3", t, 16, ByteArray(400)))
        q.offer(Packet("00000000000000a4", t, 16, ByteArray(10)))
        assertEquals(M1, q.next()!!.id); assertNull(q.next())
        t += LoraQueue.INTERVAL_MS; assertEquals("00000000000000a4", q.next()!!.id)
        t += LoraQueue.INTERVAL_MS; assertNull(q.next())
    }

    /** After a restart, packets handled earlier but no longer passed on must not be shown again when they come back. */
    @Test fun restoredSeenIdsAreNotDeliveredAgain() {
        val got = mutableListOf<String>()
        val r = MeshRouter({ _, _ -> }, { got += it.id })
        r.restore(emptyList(), listOf(M1))
        r.receive("peer", Packet(M1, System.currentTimeMillis(), 16, byteArrayOf(1)))
        assertTrue(got.isEmpty())
        r.receive("peer", Packet("00000000000000b2", System.currentTimeMillis(), 16, byteArrayOf(1)))
        assertEquals(listOf("00000000000000b2"), got)
    }
    // ---- spec "Forwarding rules": timestamps and ttl (same vectors as the iPhone's CoreTests) ----

    @Test fun packetsFromTheFutureAreDropped() {
        val t = 1_800_000_000_000L; val got = mutableListOf<String>()
        val r = MeshRouter({ _, _ -> }, { got += it.id }, now = { t })
        r.receive("p", Packet("00000000000000c1", t + MeshRouter.MAX_FUTURE_MS + 1, 16, byteArrayOf(1)))
        r.receive("p", Packet("00000000000000c2", t + MeshRouter.MAX_FUTURE_MS, 16, byteArrayOf(1)))
        assertEquals(listOf("00000000000000c2"), got)
        val sent = mutableListOf<String>()
        val r2 = MeshRouter({ _, p -> sent += p.id }, { }, now = { t })
        r2.restore(listOf(Packet("00000000000000c3", t + 3_600_000, 16, byteArrayOf(1)), Packet("00000000000000c4", t, 16, byteArrayOf(1))))
        r2.peerUp("x")
        assertEquals(listOf("00000000000000c4"), sent) // the forged future packet is not kept
    }

    @Test fun ttlAbove16IsLowered() {
        val delivered = mutableListOf<Int>(); val forwarded = mutableListOf<Int>()
        val r = MeshRouter({ _, p -> forwarded += p.ttl }, { delivered += it.ttl })
        r.peerUp("a"); r.peerUp("b")
        r.receive("a", Packet("00000000000000d1", System.currentTimeMillis(), 64, byteArrayOf(1)))
        assertEquals(listOf(16), delivered)    // stored with 16
        assertEquals(listOf(15), forwarded)    // and passed on with 15
        val sent = mutableListOf<Int>()
        val r2 = MeshRouter({ _, p -> sent += p.ttl }, { })
        r2.restore(listOf(Packet("00000000000000d2", System.currentTimeMillis(), 40, byteArrayOf(1)))); r2.peerUp("x")
        assertEquals(listOf(15), sent)
    }

    @Test fun restoreSendsNewPacketsToPeersAlreadyLinked() {
        val sent = mutableListOf<String>()
        val r = MeshRouter({ _, p -> sent += p.id }, { })
        r.peerUp("x")
        r.restore(listOf(Packet("00000000000000e1", System.currentTimeMillis(), 16, byteArrayOf(1))))
        assertEquals(listOf("00000000000000e1"), sent)
    }

    // ---- spec "Storage": the store cap ----

    @Test fun storeCapDropsUnreadableThenPublicThenGroup() {
        val e = listOf(
            StoreCap.Entry("g1", 1, 100, StoreCap.Kind.GROUP), StoreCap.Entry("p1", 2, 100, StoreCap.Kind.PUBLIC),
            StoreCap.Entry("u2", 5, 100, StoreCap.Kind.UNREADABLE), StoreCap.Entry("u1", 3, 100, StoreCap.Kind.UNREADABLE),
            StoreCap.Entry("p2", 4, 100, StoreCap.Kind.PUBLIC), StoreCap.Entry("g2", 6, 100, StoreCap.Kind.GROUP))
        assertEquals(emptyList<String>(), StoreCap.overflow(e, maxBytes = 600, maxCount = 6))
        assertEquals(listOf("u1", "u2", "p1"), StoreCap.overflow(e, maxBytes = 300, maxCount = 6))
        assertEquals(listOf("u1", "u2", "p1", "p2", "g1"), StoreCap.overflow(e, maxBytes = 10_000, maxCount = 1))
        assertEquals(listOf("u1"), StoreCap.overflow(e, maxBytes = 550, maxCount = 6))
    }

    // ---- spec "Wi-Fi networks": duplicate links ----

    @Test fun duplicateLinkRuleIsTheSameOnBothPhones() {
        val a = "259b6c4d-e98"; val b = "7c0d995b-2c4" // a < b
        // Both dialed at about the same time: both keep the link a dialed.
        assertFalse(DuplicateLinks.keepNew(a, b, newDialedByMe = false, oldDialedByMe = true, oldAgeMs = 500))  // at a: new = b's
        assertTrue(DuplicateLinks.keepNew(b, a, newDialedByMe = false, oldDialedByMe = true, oldAgeMs = 500))   // at b: new = a's
        assertTrue(DuplicateLinks.keepNew(a, b, newDialedByMe = true, oldDialedByMe = false, oldAgeMs = 500))   // at a: new = a's
        assertFalse(DuplicateLinks.keepNew(b, a, newDialedByMe = true, oldDialedByMe = false, oldAgeMs = 500))  // at b: new = b's
        // The same phone dialed again (a restart), or the old link is older: the new one replaces it.
        assertTrue(DuplicateLinks.keepNew(a, b, newDialedByMe = false, oldDialedByMe = false, oldAgeMs = 500))
        assertTrue(DuplicateLinks.keepNew(a, b, newDialedByMe = false, oldDialedByMe = true, oldAgeMs = 10_000))
    }

    @Test fun recentIdsForgetTheOldest() {
        val r = RecentIds(3, listOf("a", "b"))
        assertTrue(r.add("c")); assertFalse(r.add("a")); assertTrue(r.add("d"))
        assertEquals(listOf("b", "c", "d"), r.toList()); assertFalse("a" in r)
    }

    @Test fun receiptsWaitForAQuietMomentButNotLong() {
        assertFalse(ReceiptBatch.due(firstMs = 0, lastMs = 0, nowMs = 1_999))
        assertTrue(ReceiptBatch.due(firstMs = 0, lastMs = 0, nowMs = 2_000))
        assertFalse(ReceiptBatch.due(firstMs = 0, lastMs = 9_000, nowMs = 9_999))  // still arriving
        assertTrue(ReceiptBatch.due(firstMs = 0, lastMs = 9_500, nowMs = 10_000))  // but at most 10 s
    }
}
