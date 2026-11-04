package it.blackout.mesh

import android.content.Context
import android.graphics.Color
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * DEBUG BUILDS ONLY. A test transport over plain TCP, so two emulators (which cannot reach each
 * other over Bluetooth or Wi-Fi Direct) can exchange mesh packets. Packets go through the same
 * MeshRouter and GroupCrypto as the real transport, so chat, relaying, and encryption are exercised.
 * It runs next to Nearby and LoRa and does not replace them. It does NOT test Bluetooth or Wi-Fi Direct.
 * Each frame on the wire is a 4-byte length followed by Packet.encode().
 */
class LanTransport(private val router: () -> MeshRouter?, private val changed: () -> Unit) {
    companion object {
        const val PREFIX = "lan:"
        private const val MAX_FRAME = Packet.MAX_CIPHER + 64
        private const val RETRY_MS = 5_000L
    }
    private class Link(val socket: Socket) {
        val out = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))
        val writer = Executors.newSingleThreadExecutor()
    }
    private val links = ConcurrentHashMap<String, Link>()
    private val ids = AtomicInteger()
    private val listening = AtomicBoolean()
    private val dialGen = AtomicInteger()
    @Volatile private var server: ServerSocket? = null
    @Volatile private var target: String? = null
    @Volatile private var outgoing: Socket? = null
    @Volatile private var note = ""

    fun linkCount() = links.size
    fun listeningPort() = server?.localPort ?: 0

    /** Called by the router, possibly while it holds its lock, so the write happens on the link's own thread. */
    fun send(peer: String, p: Packet) {
        val l = links[peer] ?: return
        val b = p.encode()
        try {
            l.writer.execute {
                try { l.out.writeInt(b.size); l.out.write(b); l.out.flush() } catch (_: IOException) { quiet(l.socket) }
            }
        } catch (_: RejectedExecutionException) { } // link already closed
    }

    /** Accepts incoming links on [port] (0 = any free port) until stop(). */
    fun listen(port: Int) {
        if (!listening.compareAndSet(false, true)) return
        thread(isDaemon = true, name = "lan-listen") {
            val ss = try { ServerSocket(port) } catch (e: IOException) {
                listening.set(false); update("can't listen on port $port: ${e.message}"); return@thread
            }
            server = ss; update("")
            try {
                while (true) { val s = ss.accept(); thread(isDaemon = true, name = "lan-in") { serve(s) } }
            } catch (_: IOException) {
            } finally { quiet(ss); server = null; listening.set(false); changed() }
        }
    }

    /** Keeps one outgoing link to host:port, redialing every 5 s, until stop() or another connect(). */
    fun connect(host: String, port: Int) {
        val gen = dialGen.incrementAndGet()
        target = "$host:$port"; outgoing?.let(::quiet)
        thread(isDaemon = true, name = "lan-dial") {
            while (dialGen.get() == gen) {
                val s = Socket()
                try {
                    s.connect(InetSocketAddress(host, port), RETRY_MS.toInt())
                    if (dialGen.get() != gen) { quiet(s); break }
                    outgoing = s; update("")
                    serve(s)
                } catch (e: IOException) {
                    quiet(s); if (dialGen.get() == gen) update("can't reach $host:$port, retrying")
                }
                if (outgoing === s) outgoing = null
                if (dialGen.get() == gen) Thread.sleep(RETRY_MS)
            }
        }
    }

    fun stop() {
        dialGen.incrementAndGet(); target = null
        outgoing?.let(::quiet); server?.let(::quiet)
        links.values.forEach { quiet(it.socket) }
        update("")
    }

    fun statusLine(): String? {
        val parts = ArrayList<String>()
        server?.let { parts += "listening on ${it.localPort}" }
        target?.let { parts += (if (outgoing != null) "connected to " else "connecting to ") + it }
        if (parts.isEmpty() && links.isEmpty() && note.isEmpty()) return null
        parts += "${links.size} link(s)"
        if (note.isNotEmpty()) parts += note
        return "LAN test: " + parts.joinToString(" · ")
    }

    /** Runs one link until it drops. Blocks the calling thread. */
    private fun serve(s: Socket) {
        val r = router() ?: run { quiet(s); update("mesh not started yet"); return }
        val id = PREFIX + ids.incrementAndGet()
        try {
            s.tcpNoDelay = true
            links[id] = Link(s)
            r.peerUp(id); changed()
            val inp = DataInputStream(BufferedInputStream(s.getInputStream()))
            while (true) {
                val n = inp.readInt()
                if (n !in 1..MAX_FRAME) break
                val raw = ByteArray(n).also { inp.readFully(it) }
                Packet.decode(raw)?.let { r.receive(id, it) }
            }
        } catch (_: IOException) {
        } finally {
            links.remove(id)?.writer?.shutdown(); quiet(s)
            r.peerDown(id); changed()
        }
    }

    private fun update(n: String) { note = n; changed() }
    private fun quiet(c: Closeable) { try { c.close() } catch (_: IOException) { } }
}

/** Debug build: the LAN test mode. The release source set has an empty stub with the same API. */
object LanTest {
    const val PORT = 7777
    private val lan = LanTransport({ MeshEngine.router }, { MeshEngine.notifyUi() })

    fun owns(peer: String) = peer.startsWith(LanTransport.PREFIX)
    fun send(peer: String, p: Packet) = lan.send(peer, p)
    fun linkCount() = lan.linkCount()
    fun statusLine() = lan.statusLine()

    fun panel(c: Context): View? = LinearLayout(c).apply {
        orientation = LinearLayout.VERTICAL
        fun note(s: String) = TextView(c).apply { text = s; setTextColor(Color.WHITE); textSize = 14f }
        addView(note("DEBUG BUILD ONLY. Links emulators over TCP to test chat, relaying, and encryption. " +
            "This does NOT test Bluetooth or Wi-Fi Direct."))
        addView(note("Emulator A: tap Listen, then on the computer run\n" +
            "adb -s <emulator A> forward tcp:$PORT tcp:$PORT\nEmulator B: connect to 10.0.2.2:$PORT"))
        addView(Button(c).apply { text = "Listen on port $PORT"; setOnClickListener { lan.listen(PORT) } })
        val addr = EditText(c).apply { setText("10.0.2.2:$PORT"); setTextColor(Color.WHITE); isSingleLine = true }
        addView(addr)
        addView(Button(c).apply { text = "Connect"; setOnClickListener {
            val a = addr.text.toString().trim()
            val host = a.substringBeforeLast(':', ""); val port = a.substringAfterLast(':').toIntOrNull()
            if (host.isEmpty() || port == null || port !in 1..65535) Toast.makeText(c, "Use host:port, e.g. 10.0.2.2:$PORT", Toast.LENGTH_LONG).show()
            else lan.connect(host, port)
        } })
        addView(Button(c).apply { text = "Stop LAN test"; setOnClickListener { lan.stop() } })
    }
}
