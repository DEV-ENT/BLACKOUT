package it.blackout.mesh

import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList

/** Runs the debug LAN transport over real loopback TCP sockets, wired to real MeshRouter and GroupCrypto. */
class LanTransportTest {
    private class Node(code: String) {
        val crypto = GroupCrypto(code)
        val got = CopyOnWriteArrayList<Packet>()
        lateinit var router: MeshRouter
        val lan = LanTransport({ router }, {})
        init { router = MeshRouter({ peer, p -> lan.send(peer, p) }, { got += it }) }
        fun say(text: String): Packet {
            val id = Packet.newId(); val ts = System.currentTimeMillis()
            return Packet(id, ts, 16, crypto.seal(id, ts, "dev-$text", "Node", text)).also(router::publish)
        }
    }
    private val nodes = ArrayList<Node>()
    private fun node(code: String) = Node(code).also { nodes += it }
    @After fun tearDown() = nodes.forEach { it.lan.stop() }

    private fun waitFor(what: String, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + 15_000
        while (!cond()) { if (System.currentTimeMillis() > end) fail("timed out: $what"); Thread.sleep(20) }
    }
    private fun listen(n: Node): Int { n.lan.listen(0); waitFor("listen") { n.lan.listeningPort() > 0 }; return n.lan.listeningPort() }

    @Test fun relaysAcrossTcpChainAndOnlyGroupCanRead() {
        val a = node("group-code"); val relay = node("other-code"); val c = node("group-code")
        val pa = listen(a); val pr = listen(relay)
        relay.lan.connect("127.0.0.1", pa); c.lan.connect("127.0.0.1", pr)
        waitFor("links") { a.lan.linkCount() == 1 && relay.lan.linkCount() == 2 && c.lan.linkCount() == 1 }

        val sent = a.say("hello over tcp")
        waitFor("delivery to c") { c.got.isNotEmpty() }
        assertEquals("hello over tcp", c.crypto.open(c.got.single())!!.text)
        assertEquals(sent.id, relay.got.single().id)          // the relay stored and forwarded it...
        assertNull(relay.crypto.open(relay.got.single()))     // ...but cannot read it
        assertTrue(a.got.isEmpty())                           // no echo back to the sender

        val reply = c.say("reply")
        waitFor("reply to a") { a.got.isNotEmpty() }
        assertEquals(reply.id, a.got.single().id)
        assertEquals("reply", a.crypto.open(a.got.single())!!.text)
    }

    @Test fun dialerRetriesUntilListenerAppearsThenDeliversStoredMessage() {
        val a = node("group-code"); val b = node("group-code")
        val port = ServerSocket(0).use { it.localPort }
        b.lan.connect("127.0.0.1", port)                       // nothing listening yet: first attempt fails
        a.say("written while offline")
        Thread.sleep(300)
        assertTrue(b.lan.statusLine()!!.contains("retrying"))
        a.lan.listen(port)
        waitFor("delivery after redial") { b.got.isNotEmpty() }
        assertEquals("written while offline", b.crypto.open(b.got.single())!!.text)
    }

    @Test fun stopClosesEverything() {
        val a = node("group-code"); val b = node("group-code")
        b.lan.connect("127.0.0.1", listen(a))
        waitFor("link") { a.lan.linkCount() == 1 && b.lan.linkCount() == 1 }
        a.lan.stop()
        waitFor("links closed") { a.lan.linkCount() == 0 && b.lan.linkCount() == 0 && a.lan.listeningPort() == 0 }
        assertEquals(0, a.router.peerCount())
    }
}
