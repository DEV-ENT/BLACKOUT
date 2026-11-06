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
}
