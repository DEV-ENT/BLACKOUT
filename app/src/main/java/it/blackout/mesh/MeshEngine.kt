package it.blackout.mesh

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.util.UUID
import java.util.concurrent.Executors

private class Db(c: Context) : SQLiteOpenHelper(c, "mesh.db", null, 1) {
    override fun onCreate(d: SQLiteDatabase) = d.execSQL("CREATE TABLE p(id TEXT PRIMARY KEY, ts INTEGER, ttl INTEGER, cipher BLOB)")
    override fun onUpgrade(d: SQLiteDatabase, a: Int, b: Int) {}
}

/** Where one of my messages is: still on this phone, given to a phone in range or the relays, or confirmed. */
sealed class Delivery {
    object Waiting : Delivery()
    object Sent : Delivery()
    data class Delivered(val readers: List<Reader>) : Delivery()
}

/** State shared between the service and the UI. */
object MeshEngine {
    const val MAX_TTL = MeshRouter.MAX_TTL
    private const val WEEK = 7 * 24 * 3600_000L // how long phones pass messages on (MeshRouter)
    private const val MAX_PUBLIC = 2_000        // Public messages kept on the phone; older ones are removed
    private const val HANDED_OFF_MAX = 2_000    // "Sent" labels remembered across restarts
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var app: Context? = null
    private var db: SQLiteDatabase? = null

    /** A saved group's keys (spec/FORMAT.md, "Encryption" and "Delivery receipts"). */
    private class Keys(val code: String) { val group = GroupCrypto(code); val receipts = group.receipts() }
    private val keyCache = HashMap<String, Keys>() // code -> keys: each derivation takes 120,000 rounds, so only once
    @Volatile private var active: Keys? = null     // the group on screen
    @Volatile private var others: List<Keys> = emptyList() // the other saved groups: read, alerted and confirmed too
    @Volatile private var allKeys = false          // every saved group's key has been tried on the whole store
    @Volatile private var activeCode = ""
    private var publicCrypto: GroupCrypto? = null

    // This lock guards messages, messageIds, deliveries, index, the database writes and the key lists while they
    // change, so a packet that arrives during a group switch is neither lost nor shown twice.
    private val messages = ArrayList<Message>()      // every readable message: all saved groups and the Public channel
    private val messageIds = HashSet<String>()
    private var deliveries = Deliveries()            // who confirmed which message
    private var index = HashMap<String, StoreCap.Entry>() // every stored packet, for the store cap
    private var indexBytes = 0L
    @Volatile private var compacting = false
    private val ids = Any()                          // guards the sets below
    private val receiptIds = HashSet<String>()       // receipt packets this phone can open: kept off LoRa
    private val mine = HashSet<String>()             // ids of my own messages
    private val myReceipts = HashSet<String>()       // ids of receipts written on this phone (they go up to the relays first)
    private var handedOff = RecentIds(HANDED_OFF_MAX) // my messages already given to another phone, a radio or the relays
    private val pendingAcks = ArrayList<Pair<String, GroupCrypto>>() // message id + its group's receipt key; main thread only
    private var firstAck = 0L; private var lastAck = 0L // when the first and the last pending ack came; main thread only
    @Volatile var router: MeshRouter? = null; private set
    var sender: ((String, Packet) -> Unit)? = null
    var lora: LoraLink? = null
    var meshcore: MeshCoreLink? = null
    var ble: BleLink? = null
    /** Phones on the same Wi-Fi network; runs without the service, so it works even without Bluetooth permission. */
    @Volatile var wifi: WifiLink? = null; private set
    /** Public Nostr relays while there is internet; also bridges this phone's neighbourhood. */
    @Volatile var nostr: NostrLink? = null; private set
    /** Set by the service: node ids (Nearby endpoint names) of the phones linked over Nearby right now. */
    @Volatile var nearbyNodes: () -> Set<String> = { emptySet() }
    var listener: (() -> Unit)? = null
    /** A new message from someone else in any saved group, on the main thread (for notifications); see [Message.group]. */
    var onIncoming: ((Message) -> Unit)? = null
    var deviceId = ""; private set
    var name = ""; private set
    var transportStatus = "Starting…"
    private var startedAt = 0L

    /**
     * Opens the store and the group's keys. Called by the screen and by the service; only the first call does anything.
     * The other saved groups' keys are derived afterwards in the background, then their messages are read too.
     */
    @Synchronized fun start(c: Context, name: String, code: String) {
        if (router != null) return
        app = c.applicationContext
        val prefs = c.getSharedPreferences("mesh", 0)
        deviceId = prefs.getString("device", null) ?: UUID.randomUUID().toString().take(12).also { prefs.edit().putString("device", it).apply() }
        this.name = name
        startedAt = System.currentTimeMillis()
        synchronized(ids) { handedOff = RecentIds(HANDED_OFF_MAX, prefs.getString("handedOff", "")!!.split(',').filter { it.isNotEmpty() }) }
        publicCrypto = GroupCrypto(GroupCrypto.PUBLIC_CODE)
        db = Db(c.applicationContext).writableDatabase
        val k = keys(code)
        activeCode = code; active = k
        val loaded = scan()
        synchronized(messages) { apply(loaded) }
        router = MeshRouter(send = ::route, deliver = ::onDeliver).also { it.restore(loaded.recent, loaded.seen) }
        if (prefs.getBoolean("wifiNetwork", true)) setWifi(true)
        if (prefs.getBoolean("internet", true)) setInternet(true)
        notifyUi()
        io.execute { savedGroupsChanged(code) }
    }

    /** Turns the internet relays on or off (Connections screen), and remembers it. */
    @Synchronized fun setInternet(on: Boolean) {
        val c = app ?: return
        c.getSharedPreferences("mesh", 0).edit().putBoolean("internet", on).apply()
        nostr?.stop(); nostr = null
        val tor = Tor.enabled(c)
        if (on) nostr = NostrLink(c, { router }, ::mailboxes, ::notifyUi, tor, ::markHandedOff).also { it.start() }
        if (!on || !tor) main.post { Tor.stop(c) } // Tor runs only while the relays need it
        notifyUi()
    }

    /** Turns "Connect through Tor" on or off (Connections screen): the relays link again, through the app's own Tor or not. */
    @Synchronized fun setTor(on: Boolean) {
        val c = app ?: return
        Tor.setEnabled(c, on)
        if (nostr != null) setInternet(true) else notifyUi()
    }

    /** This phone's relay mailboxes (spec/FORMAT.md, "Mailboxes"): its group's, the other saved groups', the Public channel's. */
    private fun mailboxes(): List<Int> =
        (listOfNotNull(active?.group?.mailbox) + others.map { it.group.mailbox } + listOfNotNull(publicCrypto?.mailbox)).distinct()

    /** Turns linking over Wi-Fi networks on or off (Connections screen), and remembers it. */
    @Synchronized fun setWifi(on: Boolean) {
        val c = app ?: return
        c.getSharedPreferences("mesh", 0).edit().putBoolean("wifiNetwork", on).apply()
        if (on && wifi == null) wifi = WifiLink(c, deviceId, { router }, ::notifyUi).also { w -> main.post { w.start(); notifyUi() } }
        if (!on) { wifi?.let { w -> main.post { w.stop() } }; wifi = null; notifyUi() }
    }

    /**
     * Shows another group. Confirmations owed so far go out first. Main thread; the work runs in the background, and
     * for a saved group it is quick: its key and messages are already there.
     */
    fun switchGroup(code: String) {
        flushAcks()
        activeCode = code // shown at once; messages written now use this group's key (see post)
        io.execute { savedGroupsChanged(code) }
    }

    fun rename(newName: String) { name = newName.trim().take(40).ifEmpty { name }; notifyUi() }

    /** The cached keys of [code], derived the first time (slow: call in the background). */
    private fun keys(code: String): Keys = synchronized(keyCache) { keyCache[code] } ?: Keys(code).also { k -> synchronized(keyCache) { keyCache[code] = k } }

    /**
     * [code] is the group on screen, and the saved list may have changed: derives the keys not seen before, reads the
     * store again only if there are any, then removes what the store cap says. Background thread (io).
     */
    private fun savedGroupsChanged(code: String) {
        val c = app ?: return
        val known = synchronized(keyCache) { keyCache.keys.toSet() }
        val a = keys(code)
        val o = Groups.others(c).map { it.code }.filter { it != code }.distinct().map(::keys)
        val fresh = (o.map { it.code } + code).any { it !in known }
        synchronized(messages) { activeCode = code; active = a; others = o }
        if (fresh) scan().let { l -> synchronized(messages) { apply(l) } } // the screen keeps working while the store is read
        allKeys = true
        compact()
        nostr?.resubscribe() // the relays now send every saved group's mailbox
        notifyUi()
    }

    /** The name of the saved group whose code is [code] ([Message.group]), for alerts and labels; null if unknown. */
    fun groupName(code: String?): String? {
        val c = app ?: return null
        if (code == null) return null
        return Groups.current(c)?.takeIf { it.code == code }?.name ?: Groups.others(c).firstOrNull { it.code == code }?.name
    }

    /** What [scan] found in the store. */
    private class Loaded(val recent: List<Packet>, val seen: Set<String>, val messages: List<Message>, val receipts: List<Message>,
                         val index: Map<String, StoreCap.Entry>, val own: Set<String>, val ownReceipts: Set<String>,
                         val receiptIds: Set<String>, val future: List<String>)

    /**
     * Reads the database one row at a time with every key known so far, without holding the messages lock (the
     * screen keeps working meanwhile). Also returns what the router keeps passing on (the newest 500 of the last 7
     * days) and every id it has seen in that time. Background thread.
     */
    private fun scan(): Loaded {
        val d = db ?: return Loaded(emptyList(), emptySet(), emptyList(), emptyList(), emptyMap(), emptySet(), emptySet(), emptySet(), emptyList())
        val now = System.currentTimeMillis(); val cut = now - WEEK
        val recent = ArrayDeque<Packet>(); val seen = HashSet<String>()
        val msgs = ArrayList<Message>(); val recs = ArrayList<Message>(); val idx = HashMap<String, StoreCap.Entry>()
        val own = HashSet<String>(); val ownReceipts = HashSet<String>(); val rIds = HashSet<String>(); val future = ArrayList<String>()
        d.rawQuery("SELECT id,ts,ttl,cipher FROM p ORDER BY ts", null).use { q ->
            while (q.moveToNext()) {
                val p = MeshRouter.clamp(Packet(q.getString(0), q.getLong(1), q.getInt(2), q.getBlob(3)))
                if (MeshRouter.inFuture(p.ts, now)) { future += p.id; continue }
                if (p.ts >= cut) { seen += p.id; recent.addLast(p); if (recent.size > 500) recent.removeFirst() }
                val m = read(p)
                val kind = if (m != null) {
                    msgs += m; if (m.sender == deviceId) own += m.id
                    if (m.public) StoreCap.Kind.PUBLIC else StoreCap.Kind.GROUP
                } else readReceipt(p)?.let { r ->
                    recs += r; rIds += p.id; if (r.sender == deviceId) ownReceipts += p.id
                    StoreCap.Kind.GROUP
                } ?: StoreCap.Kind.UNREADABLE
                idx[p.id] = StoreCap.Entry(p.id, p.ts, 18 + p.cipher.size, kind)
            }
        }
        return Loaded(recent.toList(), seen, msgs, recs, idx, own, ownReceipts, rIds, future)
    }

    /**
     * Adds what [scan] found to what is shown (packets that arrived meanwhile stay, none shows twice), and removes
     * packets dated more than 10 minutes ahead. Hold the messages lock.
     */
    private fun apply(l: Loaded) {
        if (l.future.isNotEmpty()) { delete(l.future); DebugTools.log("store: removed ${l.future.size} packets dated in the future") }
        synchronized(ids) { mine += l.own; myReceipts += l.ownReceipts; receiptIds += l.receiptIds }
        var added = false
        for (m in l.messages) if (messageIds.add(m.id)) { messages += m; added = true }
        if (added) messages.sortBy { it.ts }
        l.receipts.forEach(deliveries::add)
        index.putAll(l.index) // read with the newest keys: a packet may have become readable
        indexBytes = index.values.sumOf { it.size.toLong() }
    }

    /**
     * Keeps the store small, once every saved group's key has been tried: packets older than 7 days that no saved group
     * can read go (phones stop passing them on after 7 days anyway), Public messages beyond the newest 2,000 go, and
     * then the store cap (StoreCap: about 40 MB and 20,000 packets, unreadable packets first). Background thread.
     */
    private fun compact() {
        if (!allKeys) return
        val gone = synchronized(messages) {
            val cut = System.currentTimeMillis() - WEEK
            val drop = LinkedHashSet<String>()
            index.values.filter { it.kind == StoreCap.Kind.UNREADABLE && it.ts < cut }.mapTo(drop) { it.id }
            val pub = index.values.filter { it.kind == StoreCap.Kind.PUBLIC }.sortedWith(compareBy({ it.ts }, { it.id }))
            if (pub.size > MAX_PUBLIC) pub.take(pub.size - MAX_PUBLIC).mapTo(drop) { it.id }
            drop += StoreCap.overflow(index.values.filter { it.id !in drop })
            if (drop.isNotEmpty()) {
                delete(drop.toList())
                for (id in drop) index.remove(id)?.let { indexBytes -= it.size }
                messages.removeAll { it.id in drop }; messageIds.removeAll(drop)
            }
            drop.size
        }
        compacting = false
        if (gone > 0) { DebugTools.log("store: removed $gone packets"); notifyUi() }
    }

    /** The store grew well past its cap while running: trim it in the background. */
    private fun compactIfFull() {
        if (compacting || !allKeys) return
        val full = synchronized(messages) { indexBytes > StoreCap.MAX_BYTES * 11 / 10 || index.size > StoreCap.MAX_COUNT + 1_000 }
        if (full) { compacting = true; io.execute(::compact) }
    }

    /** Hold the messages lock. */
    private fun delete(ids: List<String>) {
        val d = db ?: return
        d.beginTransaction()
        try {
            ids.chunked(500).forEach { c -> d.delete("p", "id IN (${c.joinToString(",") { "?" }})", c.toTypedArray()) }
            d.setTransactionSuccessful()
        } finally { d.endTransaction() }
    }

    /** Hold the messages lock. */
    private fun save(p: Packet, kind: StoreCap.Kind) {
        db?.insertWithOnConflict("p", null, ContentValues().apply {
            put("id", p.id); put("ts", p.ts); put("ttl", p.ttl); put("cipher", p.cipher)
        }, SQLiteDatabase.CONFLICT_IGNORE)
        if (p.id !in index) { index[p.id] = StoreCap.Entry(p.id, p.ts, 18 + p.cipher.size, kind); indexBytes += 18 + p.cipher.size }
    }

    /** Called by the router while it holds its lock: every transport only queues the packet. */
    private fun route(peer: String, p: Packet) {
        val lora = peer == LoraLink.PEER || peer == MeshCoreLink.PEER
        if (lora && synchronized(ids) { p.id in receiptIds }) return // receipts stay off LoRa, where airtime is scarce
        when {
            WifiLinks.owns(peer) -> wifi?.links?.send(peer, p)
            // Written on this phone (a message or a receipt): goes up first. "Sent" once a relay accepts it.
            NostrLink.owns(peer) -> { nostr?.send(p, mine = synchronized(ids) { p.id in mine || p.id in myReceipts }); return }
            else -> (sender ?: return)(peer, p)
        }
        if (lora && !(if (peer == LoraLink.PEER) Meshtastic.fits(p) else MeshCore.fits(p))) return // too long for the radio: not really sent
        markHandedOff(p.id)
    }

    /** One of my messages left this phone: to a phone, a radio or the internet relays ("Sent"). Saved, so it survives restarts. */
    private fun markHandedOff(id: String) {
        val list = synchronized(ids) { if (id in mine && handedOff.add(id)) handedOff.toList() else null } ?: return
        app?.getSharedPreferences("mesh", 0)?.edit()?.putString("handedOff", list.joinToString(","))?.apply()
        notifyUi()
    }

    /** A packet seen for the first time: keep it, and show it if a saved group or the Public channel can read it. */
    private fun onDeliver(p: Packet) {
        var incoming: Message? = null; var receiptKey: GroupCrypto? = null
        synchronized(messages) {
            val m = read(p)
            if (m != null) {
                save(p, if (m.public) StoreCap.Kind.PUBLIC else StoreCap.Kind.GROUP)
                if (messageIds.add(m.id)) messages.add(messages.indexOfLast { it.ts <= m.ts } + 1, m) // oldest first
                DebugTools.log("received ${p.id} ${if (m.public) "public" else "group"} from ${m.name} photo=${m.photo?.size ?: 0}")
                if (!m.public && m.sender != deviceId) { incoming = m; receiptKey = keysOf(m.group)?.receipts }
            } else {
                val r = readReceipt(p)
                save(p, if (r != null) StoreCap.Kind.GROUP else StoreCap.Kind.UNREADABLE)
                if (r != null) {
                    synchronized(ids) { receiptIds += p.id }
                    deliveries.add(r)
                    val confirmed = Receipt.ids(r.text); val mineNow = synchronized(ids) { confirmed.count { it in mine } }
                    DebugTools.log("receipt ${p.id} from ${r.name} confirms ${confirmed.size} message(s), $mineNow of mine")
                }
            }
        }
        incoming?.let { m ->
            val key = receiptKey
            main.post { if (key != null) ack(m.id, key); onIncoming?.invoke(m) } // alerts for every saved group
        }
        compactIfFull()
        notifyUi()
    }

    private fun keysOf(code: String?): Keys? = active?.takeIf { it.code == code } ?: others.firstOrNull { it.code == code }

    /**
     * This group's message, else a Public channel message (photos are group-only: dropped; others' words filtered),
     * else another saved group's message, else null (relayed, not shown). [Message.group] says which group.
     */
    private fun read(p: Packet): Message? {
        val a = active
        a?.group?.open(p)?.let { return it.copy(group = a.code) }
        publicCrypto?.open(p)?.let { return filtered(it.copy(public = true, photo = null)) }
        for (k in others) k.group.open(p)?.let { return it.copy(group = k.code) }
        return null
    }

    /** A delivery receipt of any saved group, or null. */
    private fun readReceipt(p: Packet): Message? {
        active?.receipts?.open(p)?.let { return it }
        for (k in others) k.receipts.open(p)?.let { return it }
        return null
    }

    /** Someone else's Everyone message or place with offensive words masked (WordFilter); mine as written. */
    private fun filtered(m: Message) = if (m.sender == deviceId) m else m.copy(name = WordFilter.clean(m.name), text = WordFilter.clean(m.text))

    /**
     * Confirms a group message in the next receipt, with that group's key. Messages arriving less than 2 s apart share
     * one receipt, for at most 10 s (ReceiptBatch). Main thread.
     */
    private fun ack(id: String, key: GroupCrypto) {
        val now = SystemClock.uptimeMillis()
        if (pendingAcks.isEmpty()) { firstAck = now; main.postDelayed(::ackTimer, ReceiptBatch.QUIET_MS) }
        lastAck = now
        pendingAcks += id to key
    }

    private fun ackTimer() {
        if (pendingAcks.isEmpty()) return
        val now = SystemClock.uptimeMillis()
        if (ReceiptBatch.due(firstAck, lastAck, now)) flushAcks()
        else main.postDelayed(::ackTimer, maxOf(10L, minOf(lastAck + ReceiptBatch.QUIET_MS, firstAck + ReceiptBatch.MAX_WAIT_MS) - now))
    }

    private fun flushAcks() {
        val r = router ?: return
        val batch = pendingAcks.toList(); pendingAcks.clear()
        for ((rc, msgIds) in batch.groupBy({ it.second }, { it.first })) for (b in Receipt.batches(msgIds)) {
            val id = Packet.newId(rc.mailbox); val ts = System.currentTimeMillis()
            val p = Packet(id, ts, MAX_TTL, rc.seal(id, ts, deviceId, name, Receipt.text(b)))
            synchronized(ids) { receiptIds += id; myReceipts += id }
            synchronized(messages) { save(p, StoreCap.Kind.GROUP) }
            r.publish(p)
        }
    }

    /**
     * Returns false if the message is too long for a LoRa packet. [public]: send on the Public channel. [photo]: small
     * JPEG. [group]: the code of the saved group to send to (an answer from a notification); the group on screen if null.
     */
    fun send(text: String, public: Boolean = false, photo: ByteArray? = null, group: String? = null): Boolean =
        post(deviceId, name, text, public, photo, group)

    /** A Public message typed on the Wi-Fi board by someone without the app (WifiBoard.kt). */
    fun sendFromBoard(who: String, text: String) { post("web-$deviceId", "$who (Wi-Fi board)", text, public = true) }

    private fun post(senderId: String, from: String, text: String, public: Boolean, photo: ByteArray? = null, to: String? = null): Boolean {
        val r = router ?: return true
        val ts = System.currentTimeMillis()
        val p: Packet; val id: String
        // The group on screen (or [to]); right after switching to a new group its key may still be on its way: derive it here.
        val code = to ?: activeCode
        val group = if (public) null else active?.takeIf { it.code == code } ?: others.firstOrNull { it.code == code } ?: keys(code)
        synchronized(messages) {
            val cr = (if (public) publicCrypto else group?.group) ?: return true
            id = Packet.newId(cr.mailbox)
            p = Packet(id, ts, MAX_TTL, cr.seal(id, ts, senderId, from, text, if (public) null else photo))
            save(p, if (public) StoreCap.Kind.PUBLIC else StoreCap.Kind.GROUP)
            val m = Message(id, ts, senderId, from, text, public, if (public) null else photo, if (public) null else group?.code)
            messages += if (public) filtered(m) else m; messageIds += id // Wi-Fi board posts are someone else's
        }
        synchronized(ids) { mine += id }
        r.publish(p); notifyUi()
        return Meshtastic.fits(p)
    }

    /** This group's messages and the Public channel's, oldest first. */
    fun snapshot(): List<Message> { val code = activeCode; return synchronized(messages) { messages.filter { it.public || it.group == code } } }

    /** Every saved group's messages and the Public channel's, oldest first; [Message.group] tells which group. */
    fun snapshotAll(): List<Message> = synchronized(messages) { messages.toList() }

    /** "Battery saver" (Connections): slower Bluetooth search, Nearby search in bursts, fewer relay pings. Remembered. */
    fun batterySaver(c: Context) = c.getSharedPreferences("mesh", 0).getBoolean("batterySaver", false)
    fun setBatterySaver(on: Boolean) {
        val c = app ?: return
        c.getSharedPreferences("mesh", 0).edit().putBoolean("batterySaver", on).apply()
        ble?.setSaver(on)
        if (nostr != null) setInternet(true) // relinks with the new ping interval
        notifyUi()
    }

    /** Stops every link without changing any setting, before the process ends ("Stop DarkProof"). */
    fun shutdown() {
        flushAcks()
        nostr?.stop(); nostr = null
        wifi?.stop(); wifi = null
        app?.let { Tor.stop(it) }
    }

    /** Distinct node ids of the phones linked directly right now (Nearby, Bluetooth LE, Wi-Fi network): each phone once. */
    fun linkedNodes(): Set<String> = nearbyNodes() + (ble?.nodes() ?: emptySet()) + (wifi?.links?.nodes() ?: emptySet())

    /** null for other people's messages, and for my older ones that haven't gone out yet. */
    fun delivery(m: Message): Delivery? {
        if (m.sender != deviceId) return null
        if (!m.public) synchronized(messages) { deliveries.readers(m.id) }.takeIf { it.isNotEmpty() }?.let { return Delivery.Delivered(it) }
        if (synchronized(ids) { m.id in handedOff }) return Delivery.Sent
        return if (m.ts >= startedAt) Delivery.Waiting else null
    }

    fun notifyUi() = main.post { listener?.invoke() }
}
