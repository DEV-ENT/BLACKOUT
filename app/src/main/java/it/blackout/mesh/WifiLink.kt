package it.blackout.mesh

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
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
 * TCP links to DarkProof phones on the same Wi-Fi network (spec/FORMAT.md, "Wi-Fi networks"). Plain Java sockets, so
 * unit tests run it on a computer; [WifiLink] adds Android's network service discovery on top.
 */
class WifiLinks(private val nodeId: String, private val router: () -> MeshRouter?, private val changed: () -> Unit) {
    companion object {
        const val PREFIX = "wifi:"
        const val PORT = 7777
        const val MAX_FRAME = 16_064
        const val MAX_LINKS = 32
        private const val RETRY_MS = 5_000L
        private val HELLO = "DPW1".toByteArray()
        fun owns(peer: String) = peer.startsWith(PREFIX)
    }

    private class Link(val id: String, val node: String, val socket: Socket, val out: DataOutputStream) {
        val writer = Executors.newSingleThreadExecutor()
    }
    private val links = ConcurrentHashMap<String, Link>()   // router peer id -> link
    private val byNode = ConcurrentHashMap<String, Link>()  // node id -> its current link
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()
    private val count = AtomicInteger()
    private val dialing = ConcurrentHashMap.newKeySet<String>()
    private val listening = AtomicBoolean()
    private val manualGen = AtomicInteger()
    @Volatile private var server: ServerSocket? = null
    @Volatile var manual: String? = null; private set   // "host:port" the user typed
    @Volatile var note = ""; private set

    val port get() = server?.localPort ?: 0
    fun linkCount() = links.size
    fun nodes(): Set<String> = byNode.keys.toSet()

    /** Listens on 7777, or any free port if it is taken. Returns the port, or 0 if listening failed. */
    fun listen(preferred: Int = PORT): Int {
        if (!listening.compareAndSet(false, true)) return port
        val ss = try { bind(preferred) } catch (_: IOException) {
            try { bind(0) } catch (e: IOException) { listening.set(false); update("can't listen: ${e.message}"); return 0 }
        }
        server = ss
        thread(isDaemon = true, name = "wifi-listen") {
            try { while (true) { val s = ss.accept(); thread(isDaemon = true, name = "wifi-in") { serve(s) } } }
            catch (_: IOException) { } finally { quiet(ss); server = null; listening.set(false); changed() }
        }
        return ss.localPort
    }
    private fun bind(port: Int) = ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(port)) }

    /** One attempt to link to a discovered device. */
    fun dial(host: String, port: Int) {
        val key = "$host:$port"
        if (!dialing.add(key)) return
        thread(isDaemon = true, name = "wifi-dial") {
            val s = Socket()
            try { s.connect(InetSocketAddress(host, port), 5_000); serve(s) } catch (_: IOException) { quiet(s) }
            finally { dialing.remove(key) }
        }
    }

    /** Keeps a link to an address the user typed, redialing every 5 s, until [stopManual] or another address. */
    fun connectManually(host: String, port: Int) {
        val gen = manualGen.incrementAndGet()
        manual = "$host:$port"; update("")
        thread(isDaemon = true, name = "wifi-manual") {
            while (manualGen.get() == gen) {
                val s = Socket()
                try { s.connect(InetSocketAddress(host, port), RETRY_MS.toInt()); if (manualGen.get() == gen) serve(s) else quiet(s) }
                catch (e: IOException) { quiet(s); if (manualGen.get() == gen) update("can't reach $host:$port, retrying") }
                if (manualGen.get() == gen) Thread.sleep(RETRY_MS)
            }
        }
    }

    fun stopManual() { manualGen.incrementAndGet(); manual = null; update("") }

    fun stop() {
        stopManual()
        server?.let(::quiet)
        sockets.forEach(::quiet)
        update("")
    }

    /** Called by the router, possibly while it holds its lock: the write happens on the link's own thread. */
    fun send(peer: String, p: Packet) {
        val l = links[peer] ?: return
        val b = p.encode()
        try {
            l.writer.execute { try { l.out.writeInt(b.size); l.out.write(b); l.out.flush() } catch (_: IOException) { quiet(l.socket) } }
        } catch (_: RejectedExecutionException) { } // link already closed
    }

    /** Runs one link until it drops: HELLO both ways, then packets. Blocks the calling thread. */
    private fun serve(s: Socket) {
        val r = router() ?: run { quiet(s); return }
        sockets += s
        var link: Link? = null
        try {
            s.tcpNoDelay = true; s.soTimeout = 15_000 // the HELLO must come quickly
            val out = DataOutputStream(BufferedOutputStream(s.getOutputStream()))
            val hello = HELLO + nodeId.toByteArray(Charsets.UTF_8)
            out.writeInt(hello.size); out.write(hello); out.flush()
            val inp = DataInputStream(BufferedInputStream(s.getInputStream()))
            val n = inp.readInt()
            if (n !in HELLO.size + 1..HELLO.size + 64) return
            val b = ByteArray(n).also(inp::readFully)
            if (!b.copyOf(HELLO.size).contentEquals(HELLO)) return
            val node = String(b, HELLO.size, n - HELLO.size, Charsets.UTF_8)
            if (node == nodeId || links.size >= MAX_LINKS) return
            s.soTimeout = 0
            val l = Link(PREFIX + node + "#" + count.incrementAndGet(), node, s, out)
            link = l
            links[l.id] = l
            byNode.put(node, l)?.let { old -> quiet(old.socket) } // a newer link replaces the old one (restarts)
            r.peerUp(l.id); changed()
            while (true) {
                val m = inp.readInt()
                if (m !in 1..MAX_FRAME) break
                val raw = ByteArray(m).also(inp::readFully)
                Packet.decode(raw)?.let { r.receive(l.id, it) }
            }
        } catch (_: IOException) {
        } finally {
            quiet(s); sockets -= s
            link?.let { l ->
                links.remove(l.id); byNode.remove(l.node, l); l.writer.shutdown()
                r.peerDown(l.id); changed()
            }
        }
    }

    fun statusLine(): String {
        val parts = ArrayList<String>()
        parts += if (server != null) "${links.size} link(s)" else "off"
        manual?.let { parts += "address $it" }
        if (note.isNotEmpty()) parts += note
        return "Wi-Fi network: " + parts.joinToString(" · ")
    }

    private fun update(n: String) { note = n; changed() }
    private fun quiet(c: Closeable) { try { c.close() } catch (_: IOException) { } }
}

/**
 * DarkProof phones on the same Wi-Fi network, found with network service discovery (Bonjour/mDNS) and linked with
 * [WifiLinks]. Only the phone with the smaller node id connects, and it tries again every 10 s while unlinked.
 */
class WifiLink(c: Context, private val nodeId: String, router: () -> MeshRouter?, changed: () -> Unit) {
    companion object { const val SERVICE = "_darkproof._tcp" }
    val links = WifiLinks(nodeId, router, changed)
    private val nsd = c.getSystemService(NsdManager::class.java)
    private val h = Handler(Looper.getMainLooper())
    private val found = HashMap<String, Pair<String, Int>>() // node id -> host, port (main thread)
    private val toResolve = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    var running = false; private set

    fun start() {
        if (running) return
        running = true
        val port = links.listen()
        if (port == 0) return
        registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {}
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }.also { nsd.registerService(NsdServiceInfo().apply { serviceName = nodeId; serviceType = SERVICE; this.port = port }, NsdManager.PROTOCOL_DNS_SD, it) }
        discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) {}
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = h.post { if (wanted(info.serviceName)) { toResolve += info; resolveNext() } }.let { }
            override fun onServiceLost(info: NsdServiceInfo) = h.post { found.remove(info.serviceName) }.let { }
        }.also { nsd.discoverServices(SERVICE, NsdManager.PROTOCOL_DNS_SD, it) }
        h.postDelayed(::retry, 10_000)
    }

    fun stop() {
        if (!running) return
        running = false
        h.removeCallbacksAndMessages(null)
        registration?.let { runCatching { nsd.unregisterService(it) } }; registration = null
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }; discovery = null
        found.clear(); toResolve.clear(); resolving = false
        links.stop()
    }

    /** Only the smaller node id connects (spec), and not to itself. */
    private fun wanted(node: String) = node != nodeId && nodeId < node

    @Suppress("DEPRECATION") // resolveService: its replacement needs Android 14
    private fun resolveNext() {
        if (resolving || !running) return
        val info = toResolve.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(i: NsdServiceInfo, code: Int) = h.post { resolving = false; resolveNext() }.let { }
            override fun onServiceResolved(i: NsdServiceInfo) = h.post {
                resolving = false
                val host = i.host?.hostAddress
                if (host != null && running) { found[i.serviceName] = host to i.port; links.dial(host, i.port) }
                resolveNext()
            }.let { }
        })
    }

    /** Every 10 s, dials the devices it found that have no link (a link can drop while the service stays visible). */
    private fun retry() {
        if (!running) return
        val linked = links.nodes()
        found.filterKeys { it !in linked && wanted(it) }.values.forEach { (host, port) -> links.dial(host, port) }
        h.postDelayed(::retry, 10_000)
    }
}
