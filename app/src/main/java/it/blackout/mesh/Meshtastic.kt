package it.blackout.mesh

import java.io.ByteArrayOutputStream

/** Hand-encoded subset of the Meshtastic protocol (ToRadio/FromRadio). */
object Meshtastic {
    const val PAYLOAD_MAX = 233
    private const val PRIVATE_APP = 256L
    private const val BROADCAST = 0xFFFFFFFFL
    private const val HOP_LIMIT = 3L

    fun fits(p: Packet) = p.encode().size <= PAYLOAD_MAX

    fun varint(v: Long): ByteArray {
        val o = ByteArrayOutputStream(); var x = v
        while (x >= 0x80) { o.write(((x and 0x7f) or 0x80).toInt()); x = x ushr 7 }
        o.write(x.toInt()); return o.toByteArray()
    }
    private fun vf(f: Int, v: Long) = varint((f shl 3).toLong()) + varint(v)
    private fun bf(f: Int, b: ByteArray) = varint(((f shl 3) or 2).toLong()) + varint(b.size.toLong()) + b
    private fun f32(f: Int, v: Long) = varint(((f shl 3) or 5).toLong()) +
        byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte())

    fun wantConfig(nonce: Long) = vf(3, nonce)
    fun toRadioPacket(payload: ByteArray, packetId: Long): ByteArray {
        val data = vf(1, PRIVATE_APP) + bf(2, payload)
        return bf(1, f32(2, BROADCAST) + bf(4, data) + f32(6, packetId) + vf(9, HOP_LIMIT))
    }

    private fun walk(b: ByteArray, on: (field: Int, value: Long, bytes: ByteArray?) -> Unit) {
        var i = 0
        fun rv(): Long { var s = 0; var r = 0L; while (true) { val x = b[i++].toInt(); r = r or ((x and 0x7f).toLong() shl s); if (x and 0x80 == 0) return r; s += 7 } }
        while (i < b.size) {
            val tag = rv(); val f = (tag ushr 3).toInt()
            when ((tag and 7).toInt()) {
                0 -> on(f, rv(), null)
                1 -> i += 8
                2 -> { val n = rv().toInt(); on(f, 0, b.copyOfRange(i, i + n)); i += n }
                5 -> i += 4
                else -> return
            }
        }
    }
    fun fieldBytes(b: ByteArray, field: Int): ByteArray? { var r: ByteArray? = null; walk(b) { f, _, x -> if (f == field && x != null) r = x }; return r }

    class FromRadio(val payload: ByteArray?, val configComplete: Long?)
    fun parseFromRadio(b: ByteArray): FromRadio {
        var payload: ByteArray? = null; var done: Long? = null
        try {
            walk(b) { f, v, x ->
                if (f == 7) done = v
                if (f == 2 && x != null) fieldBytes(x, 4)?.let { d ->
                    var port = 0L; walk(d) { pf, pv, _ -> if (pf == 1) port = pv }
                    if (port == PRIVATE_APP) payload = fieldBytes(d, 2)
                }
            }
        } catch (_: Exception) { return FromRadio(null, null) }
        return FromRadio(payload, done)
    }
}

/** LoRa has very little bandwidth: only recent messages that fit, one at a time. */
class LoraQueue(private val now: () -> Long = System::currentTimeMillis) {
    private val q = ArrayDeque<Packet>()
    private val sent = LinkedHashSet<String>()
    private var last = 0L
    @Synchronized fun offer(p: Packet) {
        if (p.ts < now() - MAX_AGE_MS || p.encode().size > Meshtastic.PAYLOAD_MAX || !sent.add(p.id)) return
        if (sent.size > 1000) sent.remove(sent.first())
        if (q.size >= MAX_QUEUE) q.removeFirst()
        q.addLast(p)
    }
    @Synchronized fun next(): Packet? {
        if (q.isEmpty() || now() - last < INTERVAL_MS) return null
        last = now(); return q.removeFirst()
    }
    companion object { const val MAX_AGE_MS = 30 * 60_000L; const val INTERVAL_MS = 20_000L; const val MAX_QUEUE = 20 }
}
