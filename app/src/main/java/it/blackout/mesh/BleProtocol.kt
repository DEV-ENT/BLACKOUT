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

    /** A link whose other side sends no HELLO this long after the link opened is closed (spec "Limits"). */
    const val HELLO_WAIT_MS = 10_000L
    /** A central link still being set up this long after dialing is closed. */
    const val SETUP_WAIT_MS = 30_000L
    /** Re-sync and HELLO answers to a repeated HELLO, at most once per this per link (spec "Restarts"). */
    const val REPEAT_MS = 60_000L

    /**
     * A repeated HELLO with the same node id (spec "Restarts"): whether to answer with HELLO, and whether to send the
     * link every stored packet again. Each at most once a minute; the re-sync only when the link's queue is empty.
     * The first repeat is always answered, so a restarted app learns who it is linked to.
     */
    class HelloGate {
        private var answeredAt = Long.MIN_VALUE / 2
        private var resyncedAt = Long.MIN_VALUE / 2
        fun repeated(nowMs: Long, queueEmpty: Boolean): Pair<Boolean, Boolean> {
            val answer = nowMs - answeredAt >= REPEAT_MS
            if (answer) answeredAt = nowMs
            val resync = queueEmpty && nowMs - resyncedAt >= REPEAT_MS
            if (resync) resyncedAt = nowMs
            return answer to resync
        }
    }

    /**
     * Frames waiting to go out on one link, cut into chunks as they are sent. Over [maxBytes] or [maxFrames], the
     * oldest PACKET frames not yet started are dropped (the neighbour gets stored packets again on its next link);
     * HELLO frames are never dropped.
     */
    class Outbox(private val maxBytes: Int = MAX_QUEUE_BYTES, private val maxFrames: Int = MAX_QUEUE_FRAMES) {
        private val frames = ArrayDeque<Pair<ByteArray, Boolean>>() // frame, is HELLO
        private var pos = 0          // bytes of the first frame already sent
        private var peeked = 0       // length of the chunk handed out by peek()
        var bytes = 0; private set
        val isEmpty get() = frames.isEmpty()
        val count get() = frames.size

        fun add(frame: ByteArray, hello: Boolean = false) {
            frames.addLast(frame to hello); bytes += frame.size
            while (bytes > maxBytes || frames.size > maxFrames) {
                // the first frame may be half sent: never cut a frame in the middle of the stream
                val i = ((if (pos > 0 || peeked > 0) 1 else 0) until frames.size).firstOrNull { !frames[it].second } ?: break
                bytes -= frames.removeAt(i).first.size
            }
        }
        /** The next chunk of at most [size] bytes, without taking it: call [commit] once it went out. */
        fun peek(size: Int): ByteArray? {
            val f = frames.firstOrNull()?.first ?: return null
            val end = minOf(pos + size, f.size)
            peeked = end - pos
            return f.copyOfRange(pos, end)
        }
        fun commit() {
            val f = frames.firstOrNull()?.first ?: return
            pos += peeked; peeked = 0
            if (pos >= f.size) { frames.removeFirst(); bytes -= f.size; pos = 0 }
        }
        fun clear() { frames.clear(); bytes = 0; pos = 0; peeked = 0 }
    }
    const val MAX_QUEUE_BYTES = 1 shl 20  // 1 MiB: about a minute of Bluetooth LE
    const val MAX_QUEUE_FRAMES = 1_000

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
