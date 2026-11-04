package it.blackout.mesh

import java.io.ByteArrayOutputStream
import java.util.UUID

/** Bluetooth LE link protocol (spec/FORMAT.md, "Bluetooth LE"). Pure logic, no Android dependencies. */
object BleProtocol {
    val RX: UUID = UUID.fromString("33826aba-0bb0-4dfe-9c1a-86e48726ed62")   // central writes
    val TX: UUID = UUID.fromString("94eb2c34-0e66-4bea-864c-d02a7694a3d5")   // peripheral notifies
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    const val VERSION = 1
    const val HELLO = 1
    const val PACKET = 2
    private const val MAX_NODE_ID = 64
    private const val MAX_PACKET = 18 + Packet.MAX_CIPHER

    /** The same for every Blackout device: all of them relay for each other, whatever their group. */
    val SERVICE: UUID = UUID.fromString("bec33cd5-a64e-4e1a-b8c1-868db67d0df3")

    fun frame(type: Int, payload: ByteArray): ByteArray =
        byteArrayOf(type.toByte(), (payload.size ushr 8).toByte(), payload.size.toByte()) + payload

    fun hello(nodeId: String): ByteArray = frame(HELLO, byteArrayOf(VERSION.toByte()) + nodeId.toByteArray(Charsets.US_ASCII))

    /** Node id from a HELLO payload, or null if the version or id is not acceptable. */
    fun parseHello(payload: ByteArray): String? {
        if (payload.size < 2 || payload[0].toInt() != VERSION || payload.size - 1 > MAX_NODE_ID) return null
        val id = payload.copyOfRange(1, payload.size)
        return if (id.all { it in 0x20..0x7e }) String(id, Charsets.US_ASCII) else null
    }

    /** Largest chunk for an ATT MTU: MTU - 3, but never above 512, the maximum length of an attribute value. */
    fun chunkSize(mtu: Int): Int = (mtu - 3).coerceIn(20, 512)

    /** Pieces of at most [size] bytes, each sent as one write or one notification. */
    fun chunks(frame: ByteArray, size: Int): List<ByteArray> =
        (frame.indices step size).map { frame.copyOfRange(it, minOf(it + size, frame.size)) }

    /** Of two links to the same node, true means keep the one where this device is the central. */
    fun keepMyCentralLink(myId: String, remoteId: String): Boolean =
        compareBytes(myId.toByteArray(Charsets.US_ASCII), remoteId.toByteArray(Charsets.US_ASCII)) < 0

    private fun compareBytes(a: ByteArray, b: ByteArray): Int {
        for (i in 0 until minOf(a.size, b.size)) { val c = (a[i].toInt() and 0xff) - (b[i].toInt() and 0xff); if (c != 0) return c }
        return a.size - b.size
    }

    /** Rebuilds frames from chunks. Throws IllegalArgumentException on a malformed stream: the caller disconnects. */
    class Reader {
        private val buf = ByteArrayOutputStream()
        fun feed(chunk: ByteArray): List<Pair<Int, ByteArray>> {
            buf.write(chunk)
            val all = buf.toByteArray(); var i = 0
            val out = ArrayList<Pair<Int, ByteArray>>()
            while (all.size - i >= 3) {
                val type = all[i].toInt() and 0xff
                val len = (all[i + 1].toInt() and 0xff) shl 8 or (all[i + 2].toInt() and 0xff)
                val max = when (type) { HELLO -> 1 + MAX_NODE_ID; PACKET -> MAX_PACKET; else -> throw IllegalArgumentException("frame type $type") }
                require(len in 1..max) { "frame length $len" }
                if (all.size - i - 3 < len) break
                out += type to all.copyOfRange(i + 3, i + 3 + len)
                i += 3 + len
            }
            buf.reset(); buf.write(all, i, all.size - i)
            return out
        }
    }
}
