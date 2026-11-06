package it.blackout.mesh

import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** Checks the Kotlin implementation byte-for-byte against spec/test-vectors.txt, which the iPhone app also checks. */
class FormatVectorsTest {
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun unhex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private val vectors: List<Map<String, String>> =
        File("../spec/test-vectors.txt").readText(Charsets.UTF_8).split(Regex("\n\\s*\n")).map { block ->
            block.lines().filter { it.isNotBlank() && !it.startsWith("#") }
                .associate { it.substringBefore(": ") to it.substringAfter(": ") }
        }.filter { it.isNotEmpty() }

    private fun code(v: Map<String, String>) = v["code"] ?: String(unhex(v["code_hex"]!!), Charsets.UTF_8)

    @Test fun vectorFileHasAllKinds() {
        assertEquals(4, vectors.count { it["kind"] == "kdf" }) // includes the Public channel code
        assertEquals(2, vectors.count { it["kind"] == "seal" })
    }

    @Test fun keyDerivationMatches() = vectors.filter { it["kind"] == "kdf" }.forEach { v ->
        assertEquals(v.toString(), v["key"], hex(GroupCrypto.deriveKey(code(v))))
    }

    @Test fun sealProducesIdenticalPacket() = vectors.filter { it["kind"] == "seal" }.forEach { v ->
        val id = v["id"]!!; val ts = v["ts"]!!.toLong()
        val cipher = GroupCrypto(code(v)).seal(id, ts, v["sender"]!!, v["name"]!!, v["text"]!!, iv = unhex(v["iv"]!!))
        assertEquals(v["name"], v["packet"], hex(Packet(id, ts, v["ttl"]!!.toInt(), cipher).encode()))
    }

    @Test fun vectorPacketsDecodeAndOpen() = vectors.filter { it["kind"] == "seal" }.forEach { v ->
        val p = Packet.decode(unhex(v["packet"]!!))!!
        assertEquals(v["id"], p.id); assertEquals(v["ts"]!!.toLong(), p.ts); assertEquals(v["ttl"]!!.toInt(), p.ttl)
        val m = GroupCrypto(code(v)).open(p)!!
        assertEquals(v["sender"], m.sender); assertEquals(v["name"], m.name); assertEquals(v["text"], m.text)
        assertNull(GroupCrypto("wrong-code").open(p))
    }

    @Test fun oldV02PacketsAreRejected() {
        val raw = unhex(vectors.first { it["kind"] == "seal" }["packet"]!!).also { it[0] = 0xB1.toByte() }
        assertNull(Packet.decode(raw))
    }
}
