package it.blackout.mesh

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest

/**
 * Event ids checked against Python's json.dumps (NIP-01 serialization) and signatures against @noble/curves 1.9.7.
 * The full-event vector depends on Nostr.KIND: regenerate it if the kind changes.
 */
class NostrTest {
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    @Test fun eventIdEscapesLikeNip01() {
        assertEquals("3f0e953ed7197fc8da43de56655cad42cf3a57e4221e66a5f78f6e9e016d9405",
            Nostr.eventId("ab".repeat(32), 1_700_000_000, 1, listOf(listOf("t", "x")), "a\"b\\c\nd\te\u0001é🙂"))
    }

    private val packet = Packet("a8d0000000000001", 1_793_990_000_000, 16, byteArrayOf(1, 2, 3))
    private val secret = MessageDigest.getInstance("SHA-256").digest("darkproof-test-key".toByteArray())

    @Test fun signedEventMatchesNoble() {
        val e = Nostr.event(packet, secret, now = 1_793_990_000, aux = ByteArray(32) { 2 })
        assertEquals("6dd447ac274cd77ed2bb1373b5571a181271583014de6a085437d709bc613bd5", e.getString("pubkey"))
        assertEquals("sqjQAAAAAAABAAABobIi/YAQAQID", e.getString("content"))
        assertEquals("[[\"t\",\"dp1-a8d0\"],[\"x\",\"a8d0000000000001\"],[\"expiration\",\"1794594800\"]]", e.getJSONArray("tags").toString())
        assertEquals(EXPECTED_ID, e.getString("id"))
        assertEquals(EXPECTED_SIG, e.getString("sig"))
        assertTrue(Schnorr.verify(Schnorr.publicKey(secret), e.getString("id").chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
            e.getString("sig").chunked(2).map { it.toInt(16).toByte() }.toByteArray()))
    }

    @Test fun readsEventsAndBuildsFilters() {
        val e = Nostr.event(packet, secret)
        val r = Nostr.received(JSONArray().put("EVENT").put("sub1").put(e).toString())!!
        assertEquals("a8d0000000000001", r.packet.id); assertEquals(e.getString("id"), r.eventId)
        assertNull(Nostr.received("[\"EOSE\",\"sub1\"]"))
        assertNull(Nostr.received("[\"EVENT\",\"sub1\",{\"kind\":1,\"content\":\"hi\"}]"))
        assertNull(Nostr.received("not json"))
        val req = JSONArray(Nostr.subscribe("s", listOf(0xa8d0, 0x0794), now = 1_793_990_000))
        val f = req.getJSONObject(2)
        assertEquals(Nostr.KIND, f.getJSONArray("kinds").getInt(0))
        assertEquals("[\"dp1-a8d0\",\"dp1-0794\"]", f.getJSONArray("#t").toString())
        assertEquals(1_793_990_000 - Nostr.KEEP_S, f.getLong("since"))
        val have = JSONArray(Nostr.have("h", listOf("a8d0000000000001", "07940000000000ff"))).getJSONObject(2)
        assertEquals("[\"a8d0000000000001\",\"07940000000000ff\"]", have.getJSONArray("#x").toString())
        assertEquals(2, have.getInt("limit"))
    }

    @Test fun readsTorCheck() {
        assertTrue(Tor.isTor("{\"IsTor\":true,\"IP\":\"185.220.101.1\"}"))
        assertFalse(Tor.isTor("{\"IsTor\":false,\"IP\":\"1.2.3.4\"}"))
        assertFalse(Tor.isTor("<html>blocked</html>"))
        assertFalse(Tor.isTor("{}"))
    }

    @Test fun recognizesRefusals() {
        assertEquals("banned: too many rate-limit violations", Nostr.refusal("[\"OK\",\"ab\",false,\"banned: too many rate-limit violations\"]"))
        assertNull(Nostr.refusal("[\"OK\",\"ab\",true,\"duplicate: have it\"]"))
        assertNull(Nostr.refusal("[\"EOSE\",\"s\"]"))
        assertTrue(Nostr.isThrottle("rate-limited: slow down") && Nostr.isThrottle("banned: x") && Nostr.isThrottle("rate limited") && !Nostr.isThrottle("invalid: bad sig"))
    }

    companion object {
        // From scratchpad/noble/event.mjs with kind = Nostr.KIND.
        const val EXPECTED_ID = "f1cfcc88f725896d6159d0035e17e1fca77ad130acc200a2cb798c550df4390a"
        const val EXPECTED_SIG = "eefea03d7b56a59850db2ea11651cc3988def98b4c01b1f38c6c42226b64c45a895ba6ccba4e370ca70b0ee19f944b651cb703becee4b177ae5ab21e5c573335"
    }
}
