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
        val e = Nostr.event(packet, secret, now = 1_793_990_000)
        val r = Nostr.received(JSONArray().put("EVENT").put("sub1").put(e).toString())!!
        assertEquals("a8d0000000000001", r.packet.id); assertEquals(e.getString("id"), r.eventId)
        assertNull(Nostr.received("[\"EOSE\",\"sub1\"]"))
        assertNull(Nostr.received("[\"EVENT\",\"sub1\",{\"kind\":1,\"content\":\"hi\"}]"))
        assertNull(Nostr.received("not json"))
        assertEquals(1_793_990_000L, r.createdAt); assertEquals("sub1", r.subId)
        val live = JSONArray(Nostr.live("s", listOf(0xa8d0, 0x0794), now = 1_793_990_000)).getJSONObject(2)
        assertEquals(Nostr.KIND, live.getJSONArray("kinds").getInt(0))
        assertEquals("[\"dp1-a8d0\",\"dp1-0794\"]", live.getJSONArray("#t").toString())
        assertEquals(1_793_990_000 - Nostr.KEEP_S, live.getLong("since")); assertEquals(1, live.getInt("limit"))
        val page = JSONArray(Nostr.catchUp("c", 0xa8d0, since = 1_793_000_000, until = 1_793_500_000))
        assertEquals("c", page.getString(1))
        val pf = page.getJSONObject(2)
        assertEquals("[\"dp1-a8d0\"]", pf.getJSONArray("#t").toString())
        assertEquals(1_793_000_000L, pf.getLong("since")); assertEquals(1_793_500_000L, pf.getLong("until")); assertEquals(500, pf.getInt("limit"))
        assertFalse(JSONArray(Nostr.catchUp("c", 0x0794, 1, null)).getJSONObject(2).has("until"))
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

    @Test fun readsAnswersAndEnds() {
        val ok = Nostr.ok("[\"OK\",\"ev1\",true,\"\"]")!!
        assertEquals("ev1", ok.eventId); assertTrue(ok.accepted)
        assertTrue(Nostr.ok("[\"OK\",\"ev1\",false,\"duplicate: already have this event\"]")!!.accepted)
        val no = Nostr.ok("[\"OK\",\"ev2\",false,\"blocked: web of trust\"]")!!
        assertFalse(no.accepted); assertEquals("blocked: web of trust", no.reason)
        assertNull(Nostr.ok("[\"EOSE\",\"s\"]"))
        assertTrue(Nostr.end("[\"EOSE\",\"cu1\"]")!!.let { it.subId == "cu1" && it.complete })
        assertFalse(Nostr.end("[\"CLOSED\",\"cu1\",\"rate-limited: slow down\"]")!!.complete)
        assertNull(Nostr.end("[\"NOTICE\",\"hi\"]"))
    }

    /** Same vector as the iPhone's NostrTests: SHA-256 of ts and cipher, first 16 bytes; ttl doesn't count. */
    @Test fun digestIgnoresTtl() {
        assertEquals("b37c0505ae1f3a3b344182cf27f29431", Nostr.digest(packet))
        assertEquals(Nostr.digest(packet), Nostr.digest(packet.withTtl(3)))
        assertNotEquals(Nostr.digest(packet), Nostr.digest(Packet(packet.id, packet.ts, 16, byteArrayOf(1, 2, 4))))
    }

    @Test fun relaySinceRoundTripsAndOnlyMovesForward() {
        val s = RelaySince()
        s.advance("wss://a", 0xa8d0, 100); s.advance("wss://a", 0xa8d0, 50); s.advance("wss://b", 0x0794, 7)
        val saved = s.save()
        assertEquals("wss://a|a8d0=100,wss://b|0794=7", saved)
        val t = RelaySince(saved)
        assertEquals(100L, t.get("wss://a", 0xa8d0)); assertEquals(7L, t.get("wss://b", 0x0794)); assertNull(t.get("wss://b", 0xa8d0))
    }

    /** Same scenario as the iPhone's NostrTests.testCatchUpPagesOneMailboxAtATime. */
    @Test fun catchUpPagesOneMailboxAtATime() {
        val since = RelaySince(); since.advance("wss://r", 0xa8d0, 1_000_000)
        val now = 1_100_000L
        val cu = CatchUp("wss://r", since)
        cu.add(listOf(0xa8d0, 0xbeef, Nostr.PUBLIC_MAILBOX))
        val first = cu.next(now)!!
        assertEquals(0xa8d0, first.mailbox); assertEquals(1_000_000 - Nostr.SINCE_MARGIN_S, first.since); assertNull(first.until)
        assertNull(cu.next(now))                                   // one REQ at a time
        repeat(Nostr.PAGE) { cu.event(first.subId, 1_050_000L - it) } // a full page: an older one follows
        val second = cu.end(first.subId, complete = true, now = now)!!
        assertEquals(0xa8d0, second.mailbox); assertEquals(1_050_000L - Nostr.PAGE + 1, second.until); assertEquals(first.since, second.since)
        repeat(3) { cu.event(second.subId, 1_000_000L) }
        val third = cu.end(second.subId, complete = true, now = now)!!  // not full: the next mailbox
        assertEquals(0xbeef, third.mailbox); assertEquals(now - Nostr.KEEP_S, third.since)
        assertEquals(now, since.get("wss://r", 0xa8d0))             // caught up to when the catch-up started
        val fourth = cu.end(third.subId, complete = false, now = now)!! // refused: not caught up, next mailbox
        assertNull(since.get("wss://r", 0xbeef))
        assertEquals(Nostr.PUBLIC_MAILBOX, fourth.mailbox)
        repeat(Nostr.PAGE) { cu.event(fourth.subId, 1_090_000L) }
        assertNull(cu.end(fourth.subId, complete = true, now = now)) // the Public channel gets one page only
        assertEquals(now, since.get("wss://r", Nostr.PUBLIC_MAILBOX))
        cu.live(0xa8d0, now + 50, now + 60); assertEquals(now + 50, since.get("wss://r", 0xa8d0))
        cu.live(0xa8d0, now + 9_999, now + 70); assertEquals(now + 70, since.get("wss://r", 0xa8d0)) // never past now
        cu.live(0xbeef, now + 80, now + 90); assertNull(since.get("wss://r", 0xbeef))               // not caught up here
        val repeatSecond = CatchUp("wss://r", RelaySince()); repeatSecond.add(listOf(0x0001))
        val p1 = repeatSecond.next(now)!!; repeat(Nostr.PAGE) { repeatSecond.event(p1.subId, 5L) }
        val p2 = repeatSecond.end(p1.subId, true, now)!!; assertEquals(5L, p2.until)
        repeat(Nostr.PAGE) { repeatSecond.event(p2.subId, 5L) }
        assertEquals(4L, repeatSecond.end(p2.subId, true, now)!!.until) // a full second: step past it
    }

    private fun pkt(n: Int, ts: Long, cipher: ByteArray = byteArrayOf(n.toByte())) = Packet("a8d0%012x".format(n), ts, 15, cipher)

    /** Same as the iPhone's testBridgedPacketsWaitBeforeTheLookup. */
    @Test fun bridgedPacketsWaitBeforeTheLookup() {
        var t = 1_800_000_000_000L
        val o = RelayOutbox(now = { t }, jitter = { 20_000L })
        o.offer(pkt(1, t - 1_000), mine = false)
        assertTrue(o.toCheck(50).isEmpty())                     // not yet: another phone may post it first
        t += 20_000
        assertEquals(listOf(pkt(1, 0).id), o.toCheck(50).map { it.id })
        o.offer(pkt(2, t - 1_000), mine = true)                 // own packets never wait
        assertEquals(pkt(2, 0).id, o.next(bridged = false)!!.first.id)
    }

    /** Same scenario as the iPhone's NostrTests.testOutbox. */
    @Test fun outboxCountsSentOnlyWhenARelayAccepts() {
        var t = 1_800_000_000_000L
        val o = RelayOutbox(now = { t }, jitter = { 0L })
        o.offer(pkt(1, t - 1_000), mine = true)                 // fresh own: straight up
        o.offer(pkt(2, t - 5 * 60_000), mine = true)            // older own: looked up first
        o.offer(pkt(3, t - 8 * 24 * 3_600_000L), mine = false)  // too old: never
        val (p1, own) = o.next(bridged = false)!!
        assertEquals(pkt(1, 0).id, p1.id); assertTrue(own); assertNull(o.next(bridged = true))
        o.posted("ev1", p1, own, setOf("r1", "r2"))
        assertNull(o.answer("r1", Nostr.Ok("ev1", false, "blocked: not in web of trust")))
        assertFalse(o.isSent(p1.id))
        assertEquals(p1.id, o.answer("r2", Nostr.Ok("ev1", true, "")))  // sent once one relay took it
        assertTrue(o.isSent(p1.id)); assertTrue(o.changed); assertEquals(listOf(p1.id), o.sentList()); assertFalse(o.changed)
        o.offer(p1, mine = true); assertNull(o.next(bridged = true))      // never twice

        // #x lookup: a relay copy with other contents doesn't count
        val batch = o.toCheck(50); assertEquals(listOf(pkt(2, 0).id), batch.map { it.id })
        o.fromRelay(Packet(batch[0].id, batch[0].ts, 9, byteArrayOf(99)))
        assertEquals(emptyList<String>(), o.checked(batch))
        val (p2, own2) = o.next(bridged = true)!!; assertEquals(batch[0].id, p2.id); assertFalse(own2)

        // every relay refused: queued again, at most 3 tries
        o.posted("ev2", p2, own2, setOf("r1"))
        o.answer("r1", Nostr.Ok("ev2", false, "invalid: too large"))
        val (again, _) = o.next(bridged = true)!!; assertEquals(p2.id, again.id)
        o.posted("ev3", again, false, setOf("r1"))
        t += RelayOutbox.ANSWER_MS; o.expire()                            // no answer in 30 s
        val (third, _) = o.next(bridged = true)!!; assertEquals(p2.id, third.id)
        o.posted("ev4", third, false, setOf("r1")); o.answer("r1", Nostr.Ok("ev4", false, "error"))
        assertNull(o.next(bridged = true))                                // given up until offered again
        assertEquals(p2.id, o.answer("r1", Nostr.Ok("ev3", true, "")))    // a late acceptance still counts

        // a relay copy with the same contents (any ttl) means it's there
        val p4 = pkt(4, t - 10 * 60_000); o.offer(p4, mine = false)
        val b2 = o.toCheck(50); o.fromRelay(p4.withTtl(2))
        assertEquals(listOf(p4.id), o.checked(b2)); assertTrue(o.isSent(p4.id))
        val p5 = pkt(5, t - 1_000); o.fromRelay(p5); o.offer(p5, mine = true); assertNull(o.next(bridged = true)) // came from relays
    }

    @Test fun outboxQueuesKeepTheNewest() {
        val t = 1_800_000_000_000L
        val o = RelayOutbox(now = { t }, jitter = { 0L })
        for (i in 0 until RelayOutbox.OWN_MAX + 10) o.offer(pkt(i, t - 60_000 + i), mine = true)
        assertEquals(RelayOutbox.OWN_MAX, o.queued())
        o.offer(pkt(100_000, t - 61_000), mine = true)                   // full, and older than all: not taken
        assertEquals(RelayOutbox.OWN_MAX, o.queued())
        assertEquals(pkt(RelayOutbox.OWN_MAX + 9, 0).id, o.next(false)!!.first.id)
        var last = Long.MAX_VALUE; var n = 0
        while (true) { val p = o.next(false)?.first ?: break; assertTrue(p.ts < last); last = p.ts; n++ }
        assertEquals(RelayOutbox.OWN_MAX - 1, n); assertEquals(t - 60_000 + 10, last) // the 10 oldest made room
    }

    companion object {
        // From scratchpad/noble/event.mjs with kind = Nostr.KIND.
        const val EXPECTED_ID = "f1cfcc88f725896d6159d0035e17e1fca77ad130acc200a2cb798c550df4390a"
        const val EXPECTED_SIG = "eefea03d7b56a59850db2ea11651cc3988def98b4c01b1f38c6c42226b64c45a895ba6ccba4e370ca70b0ee19f944b651cb703becee4b177ae5ab21e5c573335"
    }
}
