package it.blackout.mesh

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.Base64

/**
 * DarkProof packets as Nostr events on public relays (spec/FORMAT.md, "Internet relays"). Pure functions, so unit
 * tests run; [NostrLink] does the WebSockets. Each phone signs with a throwaway key made at every start.
 */
object Nostr {
    const val KIND = 3871  // a regular (stored) kind no one else uses (relay survey, 2026-11); see spec
    const val TAG_PREFIX = "dp1-"
    const val KEEP_S = 7 * 24 * 3600L    // relays may delete events after 7 days (NIP-40 expiration)

    fun tag(mailbox: Int) = TAG_PREFIX + "%04x".format(mailbox and 0xFFFF)

    /** NIP-01 string escaping, for computing event ids exactly as relays do. */
    fun quote(s: String): String = buildString {
        append('"')
        for (ch in s) when (ch) {
            '"' -> append("\\\""); '\\' -> append("\\\\"); '\n' -> append("\\n"); '\r' -> append("\\r")
            '\t' -> append("\\t"); '\b' -> append("\\b"); '\u000C' -> append("\\f")
            else -> if (ch < ' ') append("\\u%04x".format(ch.code)) else append(ch)
        }
        append('"')
    }

    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun unhex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    /** The event id: SHA-256 of [0, pubkey, created_at, kind, tags, content] serialized as NIP-01 says. */
    fun eventId(pubkey: String, createdAt: Long, kind: Int, tags: List<List<String>>, content: String): String {
        val t = tags.joinToString(",", "[", "]") { tag -> tag.joinToString(",", "[", "]") { quote(it) } }
        val ser = "[0,${quote(pubkey)},$createdAt,$kind,$t,${quote(content)}]"
        return hex(MessageDigest.getInstance("SHA-256").digest(ser.toByteArray(Charsets.UTF_8)))
    }

    /** A signed event carrying one packet in the packet's mailbox, findable by packet id, kept by relays for 7 days. */
    fun event(p: Packet, secret: ByteArray, now: Long = System.currentTimeMillis() / 1000, aux: ByteArray? = null): JSONObject {
        val pub = hex(Schnorr.publicKey(secret))
        val tags = listOf(listOf("t", tag(Packet.mailbox(p.id))), listOf("x", p.id), listOf("expiration", (now + KEEP_S).toString()))
        val content = Base64.getEncoder().encodeToString(p.encode())
        val id = eventId(pub, now, KIND, tags, content)
        val sig = if (aux == null) Schnorr.sign(secret, unhex(id)) else Schnorr.sign(secret, unhex(id), aux)
        return JSONObject().put("id", id).put("pubkey", pub).put("created_at", now).put("kind", KIND)
            .put("tags", JSONArray(tags.map { JSONArray(it) })).put("content", content).put("sig", hex(sig))
    }

    fun publish(event: JSONObject) = JSONArray().put("EVENT").put(event).toString()

    /** Subscribe to these mailboxes for the last 7 days. */
    fun subscribe(subId: String, mailboxes: Collection<Int>, now: Long = System.currentTimeMillis() / 1000): String =
        JSONArray().put("REQ").put(subId).put(JSONObject().put("kinds", JSONArray().put(KIND))
            .put("#t", JSONArray(mailboxes.map(::tag))).put("since", now - KEEP_S).put("limit", 500)).toString()

    /** Asks which of these packets the relay already has (by the "x" tag), before passing them on. */
    fun have(subId: String, packetIds: Collection<String>): String =
        JSONArray().put("REQ").put(subId).put(JSONObject().put("kinds", JSONArray().put(KIND))
            .put("#x", JSONArray(packetIds)).put("limit", packetIds.size)).toString()

    fun close(subId: String) = JSONArray().put("CLOSE").put(subId).toString()

    /** The reason, if this is a relay refusing an event (["OK", id, false, reason]); else null. */
    fun refusal(text: String): String? = runCatching {
        val a = JSONArray(text)
        if (a.getString(0) == "OK" && !a.getBoolean(2)) a.optString(3) else null
    }.getOrNull()

    /** A refusal that means "slow down": NIP-01's "rate-limited:" and "blocked:", and what relays really say
     *  ("rate limited", "banned: too many rate-limit violations"). */
    fun isThrottle(reason: String) = reason.lowercase().let { r -> listOf("rate", "banned", "blocked").any { r.startsWith(it) } }

    /** A NIP-56 report of the event that carried a Public message (kind 1984, type "spam"/"other"…). */
    fun report(eventId: String, eventPubkey: String, secret: ByteArray, now: Long = System.currentTimeMillis() / 1000): JSONObject {
        val pub = hex(Schnorr.publicKey(secret))
        val tags = listOf(listOf("e", eventId, "other"), listOf("p", eventPubkey))
        val id = eventId(pub, now, 1984, tags, "")
        return JSONObject().put("id", id).put("pubkey", pub).put("created_at", now).put("kind", 1984)
            .put("tags", JSONArray(tags.map { JSONArray(it) })).put("content", "").put("sig", hex(Schnorr.sign(secret, unhex(id))))
    }

    /** What a relay sent: a DarkProof packet (with the event id and author, for reports), or null for anything else. */
    class Received(val packet: Packet, val eventId: String, val pubkey: String)
    fun received(text: String): Received? = runCatching {
        val a = JSONArray(text)
        if (a.getString(0) != "EVENT" || a.length() < 3) return null
        val e = a.getJSONObject(2)
        if (e.getInt("kind") != KIND) return null
        val raw = Base64.getDecoder().decode(e.getString("content"))
        val p = Packet.decode(raw) ?: return null
        Received(p, e.getString("id"), e.getString("pubkey"))
    }.getOrNull()
}

/** Reports of Public messages waiting to go to the internet relays (spec/FORMAT.md, "Internet relays"). */
object NostrReports {
    private fun prefs(c: Context) = c.getSharedPreferences("mesh", 0)
    fun report(c: Context, messageId: String) {
        val s = (pending(c) + messageId).toList().takeLast(200).toSet()
        prefs(c).edit().putStringSet("reports", s).apply()
    }
    fun pending(c: Context): Set<String> = prefs(c).getStringSet("reports", emptySet())!!.toSet()
    fun sent(c: Context, ids: Collection<String>) = prefs(c).edit().putStringSet("reports", pending(c) - ids.toSet()).apply()
}

/**
 * Links to public Nostr relays while there is internet (spec/FORMAT.md, "Internet relays"). One peer for forwarding:
 * the router gives it every packet and it hands the router what arrives for this phone's mailboxes. Packets written on
 * this phone go up first. Anyone else's (this phone bridging its neighbourhood) go up only if no relay has them yet,
 * and slowly, so the same packet isn't posted by every phone that holds it and relays don't throttle us.
 */
class NostrLink(
    private val ctx: Context,
    private val router: () -> MeshRouter?,
    private val mailboxes: () -> Set<Int>,
    private val changed: () -> Unit,
    private val proxy: java.net.Proxy? = null, // Tor's SOCKS proxy, when "Connect through Tor" is on
) {
    companion object {
        const val PEER = "nostr"
        fun owns(peer: String) = peer == PEER
        /** Free public relays that stored a 22 KB event of this kind from a new key (tested 2026-11-06). */
        val RELAYS = listOf("wss://nos.lol", "wss://relay.damus.io", "wss://relay.primal.net", "wss://nostr.mom", "wss://nostr.oxtr.dev", "wss://relay.ditto.pub")
        private const val TICK_MS = 1_500L          // at most one own packet per tick
        private const val BRIDGE_EVERY = 3          // and one bridged packet every 3 ticks
        private const val CHECK_MS = 10_000L        // how often to ask relays which bridged packets they have
        private const val CHECK_WAIT_MS = 6_000L    // how long to wait for their answers
        private const val CHECK_BATCH = 50
        private const val REST_MS = 10 * 60_000L    // pause posting to a relay that says to slow down
        private const val FRESH_MS = 2 * 60_000L    // own packets younger than this go up without asking first
    }

    private val secret = Schnorr.newSecret() // a new throwaway key every start: relays can't link sessions
    private val h = android.os.Handler(android.os.Looper.getMainLooper())
    private val client = okhttp3.OkHttpClient.Builder().pingInterval(30, java.util.concurrent.TimeUnit.SECONDS)
        .apply { proxy?.let(::proxy) }.build()
    private val open = java.util.concurrent.ConcurrentHashMap<String, okhttp3.WebSocket>()
    private val sockets = java.util.concurrent.ConcurrentHashMap<String, okhttp3.WebSocket>()
    private val backoff = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private val resting = java.util.concurrent.ConcurrentHashMap<String, Long>() // relay -> post again after
    private val lock = Any()                         // guards the queues below
    private val own = HashMap<String, Packet>()      // written on this phone: up first, newest first
    private val candidates = LinkedHashMap<String, Packet>() // anyone else's, not yet checked with the relays
    private val missing = HashMap<String, Packet>()  // checked: no relay has them, so this phone posts them
    private val fromRelays = java.util.Collections.synchronizedSet(LinkedHashSet<String>())
    private val events = java.util.Collections.synchronizedMap(object : LinkedHashMap<String, Pair<String, String>>() {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Pair<String, String>>?) = size > 2_000
    }) // packet id -> (event id, author), for reports
    private val prefs = ctx.getSharedPreferences("mesh", 0)
    private val sent = LinkedHashSet(prefs.getString("relaySent", "")!!.split(',').filter { it.isNotEmpty() }) // on relays already
    @Volatile private var running = false
    @Volatile private var up = false
    private var sub = "dp" + System.nanoTime().toString(36)
    private var ticks = 0
    private var checking = false

    val connected get() = open.size
    /** True while at least one relay is linked (it then counts as one peer for the router, not as a phone). */
    val isUp get() = up
    val total get() = RELAYS.size

    fun start() {
        if (running) return
        running = true
        RELAYS.forEach(::connect)
        h.postDelayed(::pump, TICK_MS)
        h.postDelayed(::check, CHECK_MS)
    }

    fun stop() {
        running = false
        h.removeCallbacksAndMessages(null)
        sockets.values.forEach { it.close(1000, null) }; sockets.clear(); open.clear()
        if (up) { up = false; router()?.peerDown(PEER) }
        changed()
    }

    /** The group changed: ask every relay for the new mailboxes. */
    fun resubscribe() {
        val old = sub; sub = "dp" + System.nanoTime().toString(36)
        open.values.forEach { it.send(Nostr.close(old)); it.send(Nostr.subscribe(sub, mailboxes())) }
    }

    /**
     * Called by the router: queues the packet unless it came from the relays, is on them already or is too old.
     * [mine] = written on this phone. Older own packets may be on the relays already (the app can be killed before it
     * saves what it posted), so they are looked up first, like anyone else's.
     */
    fun send(p: Packet, mine: Boolean) {
        val now = System.currentTimeMillis()
        if (p.id in fromRelays || p.ts < now - Nostr.KEEP_S * 1000) return
        synchronized(lock) {
            if (p.id in sent) return
            if (mine && p.ts > now - FRESH_MS) own[p.id] = p
            else if (p.id !in missing) {
                candidates[p.id] = p
                if (candidates.size > 5_000) candidates.remove(candidates.keys.first())
            }
        }
    }

    private fun connect(url: String) {
        if (!running) return
        val ws = client.newWebSocket(okhttp3.Request.Builder().url(url).build(), object : okhttp3.WebSocketListener() {
            override fun onOpen(ws: okhttp3.WebSocket, r: okhttp3.Response) {
                open[url] = ws; backoff.remove(url)
                ws.send(Nostr.subscribe(sub, mailboxes()))
                if (!up) { up = true; router()?.peerUp(PEER) } // the router then offers every stored packet
                changed()
            }
            override fun onMessage(ws: okhttp3.WebSocket, text: String) {
                Nostr.refusal(text)?.let { why ->
                    android.util.Log.w("DarkProof", "relay $url refused an event: ${why.take(150)}")
                    if (Nostr.isThrottle(why)) resting[url] = System.currentTimeMillis() + REST_MS
                    return
                }
                val r = Nostr.received(text) ?: return
                fromRelays += r.packet.id
                if (fromRelays.size > 5_000) synchronized(fromRelays) { fromRelays.iterator().let { it.next(); it.remove() } }
                events[r.packet.id] = r.eventId to r.pubkey
                router()?.receive(PEER, r.packet) // also answers to have(): the router ignores packets it already has
            }
            override fun onClosed(ws: okhttp3.WebSocket, code: Int, reason: String) = lost(url, ws)
            override fun onFailure(ws: okhttp3.WebSocket, t: Throwable, r: okhttp3.Response?) = lost(url, ws)
        })
        sockets[url] = ws
    }

    private fun lost(url: String, ws: okhttp3.WebSocket) {
        if (sockets[url] !== ws) return
        sockets.remove(url); open.remove(url)
        if (open.isEmpty() && up) { up = false; router()?.peerDown(PEER) }
        changed()
        if (!running) return
        val wait = ((backoff[url] ?: 2_500L) * 2).coerceAtMost(120_000L) // no internet: try again, less and less often
        backoff[url] = wait
        h.postDelayed({ connect(url) }, wait)
    }

    /** Every tick: one own packet, else (every few ticks) one bridged packet no relay had, else pending reports. */
    private fun pump() {
        if (!running) return
        ticks++
        if (open.isNotEmpty()) {
            val p = synchronized(lock) {
                own.values.maxByOrNull { it.ts }?.also { own.remove(it.id) }
                    ?: if (ticks % BRIDGE_EVERY == 0) missing.values.maxByOrNull { it.ts }?.also { missing.remove(it.id) } else null
            }
            if (p != null) { if (p.id !in fromRelays) post(p) } else sendReports()
        }
        h.postDelayed(::pump, TICK_MS)
    }

    private fun post(p: Packet) {
        val msg = Nostr.publish(Nostr.event(p, secret))
        val now = System.currentTimeMillis()
        open.forEach { (url, ws) -> if ((resting[url] ?: 0L) < now) ws.send(msg) }
        markSent(p.id)
    }

    private fun markSent(id: String) = synchronized(lock) {
        sent += id
        if (sent.size > 3_000) sent.remove(sent.first())
        prefs.edit().putString("relaySent", sent.joinToString(",")).apply()
    }

    /** Asks the relays which of the newest unchecked bridged packets they have; the rest go to [missing]. */
    private fun check() {
        if (!running) return
        h.postDelayed(::check, CHECK_MS)
        if (checking || open.isEmpty()) return
        val batch = synchronized(lock) {
            candidates.values.sortedByDescending { it.ts }.take(CHECK_BATCH).onEach { candidates.remove(it.id) }
        }
        if (batch.isEmpty()) return
        checking = true
        val subId = "have" + System.nanoTime().toString(36)
        val req = Nostr.have(subId, batch.map { it.id })
        open.values.forEach { it.send(req) }
        h.postDelayed({
            open.values.forEach { it.send(Nostr.close(subId)) }
            for (p in batch) if (p.id in fromRelays) markSent(p.id) else synchronized(lock) { missing[p.id] = p }
            checking = false
        }, CHECK_WAIT_MS)
    }

    private fun sendReports() {
        val done = ArrayList<String>()
        for (id in NostrReports.pending(ctx)) {
            val (eventId, author) = events[id] ?: continue // only messages that came from relays can be reported there
            val msg = Nostr.publish(Nostr.report(eventId, author, secret))
            open.values.forEach { it.send(msg) }
            done += id
        }
        if (done.isNotEmpty()) NostrReports.sent(ctx, done)
    }

    fun statusLine(): String = if (!running) "Internet: off" else "Internet: $connected of $total relays"
}
