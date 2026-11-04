package it.blackout.mesh

import org.junit.Assert.*
import org.junit.Test

class BleProtocolTest {

    @Test fun serviceUuidIsTheSpecConstant() {
        // spec/FORMAT.md: one service UUID for every Blackout device, whatever its group
        assertEquals("bec33cd5-a64e-4e1a-b8c1-868db67d0df3", BleProtocol.SERVICE.toString())
    }

    @Test fun helloBytesAndParse() {
        val f = BleProtocol.hello("7c0d995b-2c4")
        assertArrayEquals(byteArrayOf(1, 0, 13, 1) + "7c0d995b-2c4".toByteArray(), f)
        assertEquals("7c0d995b-2c4", BleProtocol.parseHello(f.copyOfRange(3, f.size)))
        assertNull(BleProtocol.parseHello(byteArrayOf(2) + "abc".toByteArray()))  // unknown version
        assertNull(BleProtocol.parseHello(byteArrayOf(1)))                        // empty id
        assertNull(BleProtocol.parseHello(byteArrayOf(1, 10)))                    // not printable
    }

    @Test fun packetSurvivesAnyChunkSize() {
        val p = Packet(Packet.newId(), 42, 16, ByteArray(5000) { it.toByte() })
        val frames = BleProtocol.hello("node-a") + BleProtocol.frame(BleProtocol.PACKET, p.encode())
        for (size in listOf(1, 20, 182, 509)) {
            val r = BleProtocol.Reader()
            val chunks = BleProtocol.chunks(frames, size)
            assertTrue(chunks.all { it.size <= size })
            val got = chunks.flatMap { r.feed(it) }
            assertEquals(listOf(BleProtocol.HELLO, BleProtocol.PACKET), got.map { it.first })
            assertEquals(p.id, Packet.decode(got[1].second)!!.id)
            assertArrayEquals(p.encode(), got[1].second)
        }
    }

    @Test fun chunkSizeNeverExceedsAttributeLimit() {
        assertEquals(20, BleProtocol.chunkSize(23))
        assertEquals(182, BleProtocol.chunkSize(185))
        assertEquals(512, BleProtocol.chunkSize(515))
        assertEquals(512, BleProtocol.chunkSize(517)) // the case that crashed: 514 > 512
    }

    @Test fun malformedStreamsAreRejected() {
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.Reader().feed(byteArrayOf(9, 0, 1, 0)) }       // unknown type
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.Reader().feed(byteArrayOf(2, 0xff.toByte(), 0xff.toByte())) } // too long
        assertThrows(IllegalArgumentException::class.java) { BleProtocol.Reader().feed(byteArrayOf(1, 0, 0)) }          // empty
        assertTrue(BleProtocol.Reader().feed(byteArrayOf(2, 0)).isEmpty())                                             // incomplete header: wait
    }

    @Test fun duplicateLinkRuleIsSymmetric() {
        assertTrue(BleProtocol.keepMyCentralLink("259b6c4d-e98", "7c0d995b-2c4"))
        assertFalse(BleProtocol.keepMyCentralLink("7c0d995b-2c4", "259b6c4d-e98"))
        assertTrue(BleProtocol.keepMyCentralLink("abc", "abcd"))
    }
}
