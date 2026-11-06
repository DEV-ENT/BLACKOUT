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
        /** A new id whose first 2 bytes are the [mailbox] (spec/FORMAT.md, "Mailboxes"), the other 6 random. */
        fun newId(mailbox: Int): String = "%04x".format(mailbox and 0xFFFF) + newId().substring(4)
        /** The mailbox of any packet id. */
        fun mailbox(id: String): Int = id.substring(0, 4).toInt(16)
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

/**
 * [public]: sent on the Public channel (spec/FORMAT.md), readable by everyone. [photo]: a small JPEG, or null.
 * [group]: the code of the saved group whose key opened it (null for Public messages). Not sent on the wire.
 */
data class Message(val id: String, val ts: Long, val sender: String, val name: String, val text: String,
                   val public: Boolean = false, val photo: ByteArray? = null, val group: String? = null)

class GroupCrypto private constructor(private val keyBytes: ByteArray, mailbox: Int?) {
    constructor(code: String) : this(deriveKey(code), null)
    /** The group's relay mailbox (spec/FORMAT.md, "Mailboxes"): receipts share it, so members get them too. */
    val mailbox: Int = mailbox ?: deriveMailbox(keyBytes)
    private val key = SecretKeySpec(keyBytes, "AES")
    private val rnd = SecureRandom()

    /** The group's delivery-receipt key (spec/FORMAT.md, "Delivery receipts"). */
    fun receipts() = GroupCrypto(deriveReceiptKey(keyBytes), mailbox)

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
        /** First 2 bytes of HMAC-SHA256(group key, "darkproof-relay-mailbox-v1"), as a number 0-65535. */
        fun deriveMailbox(groupKey: ByteArray): Int = Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(groupKey, "HmacSHA256")); doFinal("darkproof-relay-mailbox-v1".toByteArray())
        }.let { ((it[0].toInt() and 0xFF) shl 8) or (it[1].toInt() and 0xFF) }
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
    companion object {
        /** Hops a new packet gets. A received packet with more (v0.4 decoding allows up to 64) is lowered to this. */
        const val MAX_TTL = 16
        /** Packets dated more than this ahead of this phone's clock are dropped (spec/FORMAT.md, "Forwarding rules"). */
        const val MAX_FUTURE_MS = 10 * 60_000L
        fun inFuture(ts: Long, now: Long) = ts > now + MAX_FUTURE_MS
        fun clamp(p: Packet) = if (p.ttl > MAX_TTL) p.withTtl(MAX_TTL) else p
    }
    private val peers = LinkedHashSet<String>()
    private val seen = HashSet<String>()
    private val stored = LinkedHashMap<String, Packet>()
    @Synchronized fun peerCount() = peers.size
    /**
     * After a restart: [all] is passed on again; [seenIds] are packets already handled, so they aren't shown twice.
     * Packets dated in the future are left out. Peers already linked get the packets that are new to the router.
     */
    @Synchronized fun restore(all: List<Packet>, seenIds: Collection<String> = emptyList()) {
        seen += seenIds
        val t = now()
        val fresh = all.filter { !inFuture(it.ts, t) && it.id !in stored }.sortedBy { it.ts }.map(::clamp)
        fresh.forEach { seen += it.id; keep(it) }
        for (p in fresh) if (stored.containsKey(p.id)) peers.forEach { forward(it, p) }
    }
    @Synchronized fun publish(p: Packet) { seen += p.id; keep(p); peers.forEach { forward(it, p) } }
    @Synchronized fun peerDown(peer: String) { peers -= peer }
    @Synchronized fun peerUp(peer: String) { peers += peer; prune(); stored.values.forEach { forward(peer, it) } }
    /** Packets older than 7 days or more than 10 minutes in the future are dropped; ttl above 16 is lowered to 16. */
    @Synchronized fun receive(from: String, packet: Packet) {
        val t = now()
        if (packet.ts < t - retentionMs || inFuture(packet.ts, t) || !seen.add(packet.id)) return
        val p = clamp(packet)
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

/**
 * Which stored packets to remove when the store is over its cap (spec/FORMAT.md, "Storage"): first packets no saved
 * group can read, oldest first, then the oldest Public messages, and only then the oldest messages and receipts of
 * the saved groups. Same rules as the iPhone's StoreCap.
 */
object StoreCap {
    const val MAX_BYTES = 40L * 1024 * 1024
    const val MAX_COUNT = 20_000
    /** In the order they go: [UNREADABLE] first, [GROUP] last. */
    enum class Kind { UNREADABLE, PUBLIC, GROUP }
    /** [size]: the encoded packet's length. */
    class Entry(val id: String, val ts: Long, val size: Int, val kind: Kind)

    /** Ids to remove so that at most [maxBytes] and [maxCount] remain; empty if the store fits. */
    fun overflow(entries: Collection<Entry>, maxBytes: Long = MAX_BYTES, maxCount: Int = MAX_COUNT): List<String> {
        var bytes = entries.sumOf { it.size.toLong() }; var count = entries.size
        if (bytes <= maxBytes && count <= maxCount) return emptyList()
        val out = ArrayList<String>()
        for (e in entries.sortedWith(compareBy<Entry>({ it.kind.ordinal }, { it.ts }, { it.id }))) {
            if (bytes <= maxBytes && count <= maxCount) break
            out += e.id; bytes -= e.size; count--
        }
        return out
    }
}

/**
 * Two links between the same two phones (spec/FORMAT.md, "Wi-Fi networks"): which one stays. When both phones dialed
 * each other at about the same time (the older link is less than 10 s old), the link dialed by the smaller node id
 * stays, so both phones keep the same one. Otherwise, or when the same phone dialed both, the new link replaces the
 * old one: after a restart the old one may be dead without either side knowing.
 */
object DuplicateLinks {
    const val SAME_TIME_MS = 10_000L
    fun keepNew(myId: String, remoteId: String, newDialedByMe: Boolean, oldDialedByMe: Boolean, oldAgeMs: Long): Boolean {
        if (newDialedByMe == oldDialedByMe || oldAgeMs >= SAME_TIME_MS) return true
        val meSmaller = BleProtocol.keepMyCentralLink(myId, remoteId) // byte comparison of the node ids
        return if (newDialedByMe) meSmaller else !meSmaller
    }
}

/** An ordered set of ids that forgets the oldest beyond [max], for lists saved on the phone. Not thread-safe. */
class RecentIds(private val max: Int, initial: Collection<String> = emptyList()) {
    private val set = LinkedHashSet<String>()
    init { initial.forEach(::add) }
    /** True if [id] is new. */
    fun add(id: String): Boolean {
        if (!set.add(id)) return false
        while (set.size > max) set.remove(set.first())
        return true
    }
    operator fun contains(id: String) = id in set
    val size get() = set.size
    fun toList(): List<String> = set.toList()
}

/**
 * When the next delivery receipt goes out (spec/FORMAT.md, "Delivery receipts"): 2 s after the last message to
 * confirm arrived, or 10 s after the first one, so a burst of arriving messages shares one receipt.
 */
object ReceiptBatch {
    const val QUIET_MS = 2_000L
    const val MAX_WAIT_MS = 10_000L
    fun due(firstMs: Long, lastMs: Long, nowMs: Long) = nowMs - lastMs >= QUIET_MS || nowMs - firstMs >= MAX_WAIT_MS
}
