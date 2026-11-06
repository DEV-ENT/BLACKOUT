package it.blackout.mesh

import java.io.*
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Unit carried over the network, compact enough to fit in a LoRa packet. Relays see only the id, timestamp, and remaining hops.
 * Wire format: spec/FORMAT.md (shared with the iPhone app).
 */
class Packet(val id: String, val ts: Long, val ttl: Int, val cipher: ByteArray) {
    fun encode(): ByteArray = ByteArrayOutputStream().also { b ->
        DataOutputStream(b).run {
            writeByte(MAGIC); write(id.chunked(2).map { it.toInt(16).toByte() }.toByteArray())
            writeLong(ts); writeByte(ttl); write(cipher)
        }
    }.toByteArray()
    fun withTtl(t: Int) = Packet(id, ts, t, cipher)
    companion object {
        private const val MAGIC = 0xB2 // 0xB1 = v0.2 (Java modified UTF-8 text), 0xB2 = v0.3 (standard UTF-8)
        private const val HEADER = 18
        const val MAX_CIPHER = 16_000
        fun newId(): String = ByteArray(8).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        fun decode(raw: ByteArray): Packet? {
            if (raw.size <= HEADER || raw.size > HEADER + MAX_CIPHER || raw[0] != MAGIC.toByte()) return null
            return try {
                DataInputStream(ByteArrayInputStream(raw, 1, raw.size - 1)).run {
                    val id = ByteArray(8).also { readFully(it) }.joinToString("") { "%02x".format(it) }
                    val ts = readLong(); val ttl = readUnsignedByte()
                    if (ttl > 64) return null
                    Packet(id, ts, ttl, raw.copyOfRange(HEADER, raw.size))
                }
            } catch (_: Exception) { null }
        }
    }
}

/** [public]: sent on the Public channel (spec/FORMAT.md), readable by everyone. [photo]: a small JPEG, or null. */
data class Message(val id: String, val ts: Long, val sender: String, val name: String, val text: String,
                   val public: Boolean = false, val photo: ByteArray? = null)

class GroupCrypto private constructor(private val keyBytes: ByteArray) {
    constructor(code: String) : this(deriveKey(code))
    private val key = SecretKeySpec(keyBytes, "AES")
    private val rnd = SecureRandom()

    /** The group's delivery-receipt key (spec/FORMAT.md, "Delivery receipts"). */
    fun receipts() = GroupCrypto(deriveReceiptKey(keyBytes))

    /** [iv] is random in normal use; tests pass a fixed one to reproduce spec/test-vectors.txt. [photo]: 4th field. */
    fun seal(id: String, ts: Long, sender: String, name: String, text: String, photo: ByteArray? = null,
             iv: ByteArray = ByteArray(12).also(rnd::nextBytes)): ByteArray {
        require(photo == null || photo.size <= Photo.MAX_BYTES) { "photo too big" }
        val plain = ByteArrayOutputStream().also { b ->
            b.putStr(sender); b.putStr(name); b.putStr(text)
            if (photo != null) b.putBytes(byteArrayOf(Photo.JPEG) + photo)
        }.toByteArray()
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv)); c.updateAAD("$id|$ts".toByteArray())
        return iv + c.doFinal(plain)
    }

    fun open(p: Packet): Message? = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, p.cipher, 0, 12)); c.updateAAD("${p.id}|${p.ts}".toByteArray())
        DataInputStream(ByteArrayInputStream(c.doFinal(p.cipher, 12, p.cipher.size - 12))).run {
            val sender = getStr(); val name = getStr(); val text = getStr()
            val extra = if (available() >= 2) runCatching { getBytes() }.getOrNull() else null // older apps send none
            val photo = extra?.takeIf { it.size > 1 && it[0] == Photo.JPEG && it.size - 1 <= Photo.MAX_BYTES }?.copyOfRange(1, extra.size)
            Message(p.id, p.ts, sender, name, text, photo = photo)
        }
    } catch (_: Exception) { null }

    companion object {
        /**
         * PBKDF2-HMAC-SHA256 over the UTF-8 bytes of the group code, normalized to NFC first so that
         * "à" typed as one character or as "a" + accent gives the same key on every keyboard and platform.
         */
        fun deriveKey(code: String): ByteArray = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(PBEKeySpec(java.text.Normalizer.normalize(code, java.text.Normalizer.Form.NFC).toCharArray(),
                "blackout-mesh-v1".toByteArray(), 120_000, 256)).encoded
        /** HKDF-SHA256 (RFC 5869) of the group key, no salt, info "darkproof-receipt-v1", 32 bytes. */
        fun deriveReceiptKey(groupKey: ByteArray): ByteArray {
            val prk = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(ByteArray(32), "HmacSHA256")); doFinal(groupKey) }
            return Mac.getInstance("HmacSHA256").run {
                init(SecretKeySpec(prk, "HmacSHA256")); update("darkproof-receipt-v1".toByteArray()); doFinal(byteArrayOf(1))
            }
        }
        /** Text field: 2-byte big-endian length, then standard UTF-8 (not Java's modified UTF-8, so other platforms can read it). */
        private fun ByteArrayOutputStream.putStr(s: String) = putBytes(s.toByteArray(Charsets.UTF_8))
        private fun ByteArrayOutputStream.putBytes(b: ByteArray) {
            require(b.size <= 0xFFFF) { "field too long" }
            write(b.size ushr 8); write(b.size and 0xFF); write(b)
        }
        private fun DataInputStream.getStr(): String = String(getBytes(), Charsets.UTF_8)
        private fun DataInputStream.getBytes(): ByteArray = ByteArray(readUnsignedShort()).also { readFully(it) }

        /** Code of the Public channel: everyone knows it, so anyone can read and post (spec/FORMAT.md). */
        const val PUBLIC_CODE = "blackout-public"
    }
}

/** Flooding with deduplication and store-and-forward. No Android dependencies. */
class MeshRouter(
    private val send: (peer: String, p: Packet) -> Unit,
    private val deliver: (Packet) -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
    private val retentionMs: Long = 7 * 24 * 3600_000L,
    private val maxStored: Int = 500,
) {
    private val peers = LinkedHashSet<String>()
    private val seen = HashSet<String>()
    private val stored = LinkedHashMap<String, Packet>()
    @Synchronized fun peerCount() = peers.size
    @Synchronized fun restore(all: List<Packet>) = all.sortedBy { it.ts }.forEach { seen += it.id; keep(it) }
    @Synchronized fun publish(p: Packet) { seen += p.id; keep(p); peers.forEach { forward(it, p) } }
    @Synchronized fun peerDown(peer: String) { peers -= peer }
    @Synchronized fun peerUp(peer: String) { peers += peer; prune(); stored.values.forEach { forward(peer, it) } }
    @Synchronized fun receive(from: String, p: Packet) {
        if (p.ts < now() - retentionMs || !seen.add(p.id)) return
        keep(p); deliver(p)
        peers.filter { it != from }.forEach { forward(it, p) }
    }
    private fun forward(peer: String, p: Packet) { if (p.ttl > 1) send(peer, p.withTtl(p.ttl - 1)) }
    private fun keep(p: Packet) { stored[p.id] = p; prune() }
    private fun prune() {
        val cut = now() - retentionMs
        stored.values.removeAll { it.ts < cut }
        while (stored.size > maxStored) stored.remove(stored.keys.first())
    }
}
