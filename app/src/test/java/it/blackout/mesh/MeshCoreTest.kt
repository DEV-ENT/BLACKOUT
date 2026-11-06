package it.blackout.mesh

import org.junit.Assert.*
import org.junit.Test

/** Frames checked byte by byte against MeshCore's companion firmware (examples/companion_radio/MyMesh.cpp, v1.18). */
class MeshCoreTest {
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun unhex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun channelKeyIsTheHashtagKey() = assertEquals("835a8265454a846068f204bf5ea81bd3", hex(MeshCore.CHANNEL_KEY))

    @Test fun commandFrames() {
        assertEquals("1603", hex(MeshCore.deviceQuery()))
        assertEquals("01" + "00".repeat(7) + hex("DarkProof".toByteArray()), hex(MeshCore.appStart()))
        assertEquals("1f03", hex(MeshCore.getChannel(3)))
        val set = MeshCore.setChannel(2)
        assertEquals(2 + 32 + 16, set.size)
        assertEquals("2002" + hex("#darkproof".toByteArray()) + "00".repeat(22) + "835a8265454a846068f204bf5ea81bd3", hex(set))
        assertEquals("3e01ff44ff" + "aabb", hex(MeshCore.sendData(1, unhex("aabb")))) // flood, data type 0xFF44 little-endian
        assertThrows(IllegalArgumentException::class.java) { MeshCore.sendData(1, ByteArray(MeshCore.PAYLOAD_MAX + 1)) }
        assertEquals("0a", hex(MeshCore.syncNext()))
    }

    @Test fun parsesReplies() {
        val info = MeshCore.deviceInfo(unhex("0d0e2028"))!!                 // firmware 14, 64 contacts, 40 channel slots
        assertEquals(14, info.firmware); assertEquals(40, info.channels)
        assertNull(MeshCore.deviceInfo(unhex("05")))
        val ours = MeshCore.slot(unhex("1205") + "#darkproof".toByteArray().copyOf(32) + MeshCore.CHANNEL_KEY)!!
        assertTrue(ours.isOurs); assertEquals(5, ours.idx); assertEquals("#darkproof", ours.name)
        val empty = MeshCore.slot(unhex("1207") + ByteArray(48))!!
        assertTrue(empty.isEmpty); assertFalse(empty.isOurs)
        val public = MeshCore.slot(unhex("1200") + "Public".toByteArray().copyOf(32) + unhex("8b3387e9c5cdea6ac9e5edbaa115cd72"))!!
        assertFalse(public.isEmpty); assertFalse(public.isOurs)
        assertTrue(MeshCore.isPush(unhex("83"))); assertFalse(MeshCore.isPush(unhex("0a")))
    }

    @Test fun readsOnlyDarkProofChannelData() {
        val packet = unhex("b2" + "11".repeat(30))
        fun frame(slot: Int, type: Int) = byteArrayOf(0x1B, 0x10, 0, 0, slot.toByte(), 2, (type and 0xFF).toByte(), (type shr 8).toByte(), packet.size.toByte()) + packet
        assertArrayEquals(packet, MeshCore.packet(frame(4, 0xFF44), 4))
        assertNull(MeshCore.packet(frame(3, 0xFF44), 4))             // another channel slot
        assertNull(MeshCore.packet(frame(4, 0x0001), 4))             // another app's data type
        assertNull(MeshCore.packet(frame(4, 0xFF44).copyOf(20), 4))  // cut short
        assertNull(MeshCore.packet(unhex("11"), 4))                  // a channel text message
    }

    @Test fun checkInsFitButLongMessagesDont() {
        val c = GroupCrypto("group-code")
        fun packet(name: String, text: String): Packet { val id = Packet.newId(); return Packet(id, 1, 16, c.seal(id, 1, "7c0d995b-2c4", name, text)) }
        assertTrue(MeshCore.fits(packet("Anna", CheckIn.SAFE.text(23, Spot(45.4642, 9.19, 12)))))
        assertFalse(MeshCore.fits(packet("Anna", "x".repeat(120))))
        val q = LoraQueue(maxBytes = MeshCore.PAYLOAD_MAX, now = { 1L })
        q.offer(packet("Anna", "x".repeat(120))); assertNull(q.next())  // too long for MeshCore: never queued
    }
}
