package it.blackout.mesh

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.Handler
import android.os.Looper
import java.util.UUID
import java.util.concurrent.Executors

private class Db(c: Context) : SQLiteOpenHelper(c, "mesh.db", null, 1) {
    override fun onCreate(d: SQLiteDatabase) = d.execSQL("CREATE TABLE p(id TEXT PRIMARY KEY, ts INTEGER, ttl INTEGER, cipher BLOB)")
    override fun onUpgrade(d: SQLiteDatabase, a: Int, b: Int) {}
}

/** Where one of my messages is: still on this phone, given to a phone in range, or confirmed by group members. */
sealed class Delivery {
    object Waiting : Delivery()
    object Sent : Delivery()
    data class Delivered(val readers: List<Reader>) : Delivery()
}

/** State shared between the service and the UI. */
object MeshEngine {
    const val MAX_TTL = 16
    private const val WEEK = 7 * 24 * 3600_000L // how long phones pass messages on (MeshRouter)
    private const val MAX_PUBLIC = 2_000        // Public messages kept on the phone; older ones are removed
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var app: Context? = null
    private var db: SQLiteDatabase? = null
    @Volatile private var crypto: GroupCrypto? = null
    @Volatile private var receiptCrypto: GroupCrypto? = null // the group's receipt key (spec/FORMAT.md, "Delivery receipts")
    private var publicCrypto: GroupCrypto? = null
    // This lock guards messages, messageIds, deliveries, the database writes and the group keys while they change, so a
    // packet that arrives during a group switch is neither lost nor shown twice.
    private val messages = ArrayList<Message>()
    private val messageIds = HashSet<String>()
    private var deliveries = Deliveries()            // who confirmed which message
    private val ids = Any()                          // guards the three sets below
    private val receiptIds = HashSet<String>()       // receipt packets this phone can open: kept off LoRa
    private val mine = HashSet<String>()             // ids of my own messages
    private val handedOff = HashSet<String>()        // my messages already given to another phone or the radio
    private val pendingAcks = ArrayList<Pair<String, GroupCrypto>>() // message id + its group's receipt key; main thread only
    private val savedKeys = HashMap<String, Pair<GroupCrypto, GroupCrypto>>() // other saved groups' keys, for pruning
    @Volatile var router: MeshRouter? = null; private set
    var sender: ((String, Packet) -> Unit)? = null
    var lora: LoraLink? = null
    var meshcore: MeshCoreLink? = null
    var ble: BleLink? = null
    /** Phones on the same Wi-Fi network; runs without the service, so it works even without Bluetooth permission. */
    @Volatile var wifi: WifiLink? = null; private set
    /** Public Nostr relays while there is internet; also bridges this phone's neighbourhood. */
    @Volatile var nostr: NostrLink? = null; private set
    var listener: (() -> Unit)? = null
    /** A new group message from someone else, on the main thread (for notifications). */
    var onIncoming: ((Message) -> Unit)? = null
    var deviceId = ""; private set
    var name = ""; private set
    var transportStatus = "Starting…"
    private var startedAt = 0L

    /** Opens the store and the group's keys. Called by the screen and by the service; only the first call does anything. */
    @Synchronized fun start(c: Context, name: String, code: String) {
        if (router != null) return
        app = c.applicationContext
        val prefs = c.getSharedPreferences("mesh", 0)
        deviceId = prefs.getString("device", null) ?: UUID.randomUUID().toString().take(12).also { prefs.edit().putString("device", it).apply() }
        this.name = name
        startedAt = System.currentTimeMillis()
        publicCrypto = GroupCrypto(GroupCrypto.PUBLIC_CODE)
        db = Db(c.applicationContext).writableDatabase
        val (recent, seen) = synchronized(messages) { setKeys(code); load() }
        router = MeshRouter(send = ::route, deliver = ::onDeliver).also { it.restore(recent, seen) }
        if (prefs.getBoolean("wifiNetwork", true)) setWifi(true)
        if (prefs.getBoolean("internet", true)) setInternet(true)
        notifyUi()
    }

    /** Turns the internet relays on or off (Connections screen), and remembers it. */
    @Synchronized fun setInternet(on: Boolean) {
        val c = app ?: return
        c.getSharedPreferences("mesh", 0).edit().putBoolean("internet", on).apply()
        nostr?.stop(); nostr = null
        if (on) nostr = NostrLink(c, { router }, ::mailboxes, ::notifyUi, Tor.proxy(c)).also { it.start() }
        notifyUi()
    }

    /** This phone's relay mailboxes: its group's and the Public channel's (spec/FORMAT.md, "Mailboxes"). */
    private fun mailboxes(): Set<Int> = setOfNotNull(crypto?.mailbox, publicCrypto?.mailbox)

    /** Turns linking over Wi-Fi networks on or off (Connections screen), and remembers it. */
    @Synchronized fun setWifi(on: Boolean) {
        val c = app ?: return
        c.getSharedPreferences("mesh", 0).edit().putBoolean("wifiNetwork", on).apply()
        if (on && wifi == null) wifi = WifiLink(c, deviceId, { router }, ::notifyUi).also { w -> main.post { w.start(); notifyUi() } }
        if (!on) { wifi?.let { w -> main.post { w.stop() } }; wifi = null; notifyUi() }
    }

    /** Joins another group: confirmations owed to the old one go out first, with its key. Main thread; the work runs in the background. */
    fun switchGroup(code: String) {
        flushAcks()
        io.execute { synchronized(messages) { setKeys(code); load() }; nostr?.resubscribe(); notifyUi() }
    }

    fun rename(newName: String) { name = newName.trim().take(40).ifEmpty { name }; notifyUi() }

    private fun setKeys(code: String) { val c = GroupCrypto(code); crypto = c; receiptCrypto = c.receipts() }

    /** Keys of the groups the user switched away from: their messages are kept even when this group can't read them. */
    private fun otherGroupKeys(): List<Pair<GroupCrypto, GroupCrypto>> {
        val c = app ?: return emptyList()
        return Groups.others(c).map { g -> synchronized(savedKeys) { savedKeys.getOrPut(g.code) { GroupCrypto(g.code).let { it to it.receipts() } } } }
    }

    /**
     * Rebuilds messages and receipts from the database, one row at a time, and prunes it: packets older than 7 days that
     * no saved group can read are removed (phones stop passing them on after 7 days anyway), and so are Public messages
     * beyond the newest 2,000. Returns what the router keeps passing on (the newest 500 of the last 7 days) and every id
     * it has seen in that time. Hold the messages lock.
     */
    private fun load(): Pair<List<Packet>, Set<String>> {
        val d = db ?: return emptyList<Packet>() to emptySet()
        val cut = System.currentTimeMillis() - WEEK
        val others = otherGroupKeys()
        val rc = receiptCrypto
        val recent = ArrayDeque<Packet>(); val seen = HashSet<String>()
        val msgs = ArrayList<Message>(); val dl = Deliveries(); val own = HashSet<String>(); val rIds = HashSet<String>()
        val drop = ArrayList<String>()
        d.rawQuery("SELECT id,ts,ttl,cipher FROM p ORDER BY ts", null).use { q ->
            while (q.moveToNext()) {
                val p = Packet(q.getString(0), q.getLong(1), q.getInt(2), q.getBlob(3))
                if (p.ts >= cut) { seen += p.id; recent.addLast(p); if (recent.size > 500) recent.removeFirst() }
                val m = read(p)
                if (m != null) { msgs += m; if (m.sender == deviceId) own += m.id; continue }
                val r = rc?.open(p)
                if (r != null) { dl.add(r); rIds += p.id; continue }
                if (p.ts < cut && others.none { (g, gr) -> g.open(p) != null || gr.open(p) != null }) drop += p.id
            }
        }
        val pub = msgs.filter { it.public }
        if (pub.size > MAX_PUBLIC) {
            val old = pub.take(pub.size - MAX_PUBLIC).map { it.id }.toHashSet()
            msgs.removeAll { it.id in old }; drop += old
        }
        if (drop.isNotEmpty()) {
            d.beginTransaction()
            try {
                drop.chunked(500).forEach { c -> d.delete("p", "id IN (${c.joinToString(",") { "?" }})", c.toTypedArray()) }
                d.setTransactionSuccessful()
            } finally { d.endTransaction() }
            DebugTools.log("store: removed ${drop.size} old packets")
        }
        synchronized(ids) { mine += own; receiptIds += rIds }
        messages.clear(); messages += msgs
        messageIds.clear(); msgs.mapTo(messageIds) { it.id }
        deliveries = dl
        return recent.toList() to seen
    }

    private fun save(p: Packet) {
        db?.insertWithOnConflict("p", null, ContentValues().apply {
            put("id", p.id); put("ts", p.ts); put("ttl", p.ttl); put("cipher", p.cipher)
        }, SQLiteDatabase.CONFLICT_IGNORE)
    }

    /** Called by the router while it holds its lock: every transport only queues the packet. */
    private fun route(peer: String, p: Packet) {
        val lora = peer == LoraLink.PEER || peer == MeshCoreLink.PEER
        if (lora && synchronized(ids) { p.id in receiptIds }) return // receipts stay off LoRa, where airtime is scarce
        when {
            WifiLinks.owns(peer) -> wifi?.links?.send(peer, p)
            // A packet that hasn't hopped yet (one less than MAX_TTL after forward) was written on this phone.
            NostrLink.owns(peer) -> { nostr?.send(p, mine = p.ttl >= MAX_TTL - 1); return } // "handed off" = to a phone
            else -> (sender ?: return)(peer, p)
        }
        if (lora && !(if (peer == LoraLink.PEER) Meshtastic.fits(p) else MeshCore.fits(p))) return // too long for the radio: not really sent
        if (synchronized(ids) { p.id in mine && handedOff.add(p.id) }) notifyUi()
    }

    /** A packet seen for the first time: keep it, and show it if it belongs to this group or the Public channel. */
    private fun onDeliver(p: Packet) {
        var incoming: Message? = null; var group: GroupCrypto? = null; var receiptKey: GroupCrypto? = null
        synchronized(messages) {
            group = crypto; receiptKey = receiptCrypto
            save(p)
            val m = read(p)
            if (m != null) {
                if (messageIds.add(m.id)) { messages += m; messages.sortBy { it.ts } }
                DebugTools.log("received ${p.id} ${if (m.public) "public" else "group"} from ${m.name} photo=${m.photo?.size ?: 0}")
                if (!m.public && m.sender != deviceId) incoming = m
            } else {
                val r = receiptKey?.open(p)
                if (r != null) {
                    synchronized(ids) { receiptIds += p.id }
                    deliveries.add(r)
                    val confirmed = Receipt.ids(r.text); val mineNow = synchronized(ids) { confirmed.count { it in mine } }
                    DebugTools.log("receipt ${p.id} from ${r.name} confirms ${confirmed.size} message(s), $mineNow of mine")
                }
            }
        }
        incoming?.let { m ->
            val key = receiptKey!!; val g = group
            main.post { ack(m.id, key); if (crypto === g) onIncoming?.invoke(m) } // no alert for a group the user just left
        }
        notifyUi()
    }

    /** This group's message, else a Public channel message (photos are group-only: dropped), else null (relayed, not shown). */
    private fun read(p: Packet): Message? = crypto?.open(p) ?: publicCrypto?.open(p)?.copy(public = true, photo = null)

    /** Confirms a group message in the next receipt, with that group's key; messages within 2 seconds share one. Main thread. */
    private fun ack(id: String, key: GroupCrypto) {
        pendingAcks += id to key
        if (pendingAcks.size == 1) main.postDelayed(::flushAcks, 2_000)
    }

    private fun flushAcks() {
        val r = router ?: return
        val batch = pendingAcks.toList(); pendingAcks.clear()
        for ((rc, msgIds) in batch.groupBy({ it.second }, { it.first })) for (b in Receipt.batches(msgIds)) {
            val id = Packet.newId(rc.mailbox); val ts = System.currentTimeMillis()
            val p = Packet(id, ts, MAX_TTL, rc.seal(id, ts, deviceId, name, Receipt.text(b)))
            synchronized(ids) { receiptIds += id }
            synchronized(messages) { save(p) }
            r.publish(p)
        }
    }

    /** Returns false if the message is too long for a LoRa packet. [public]: send on the Public channel. [photo]: small JPEG. */
    fun send(text: String, public: Boolean = false, photo: ByteArray? = null): Boolean = post(deviceId, name, text, public, photo)

    /** A Public message typed on the Wi-Fi board by someone without the app (WifiBoard.kt). */
    fun sendFromBoard(who: String, text: String) { post("web-$deviceId", "$who (Wi-Fi board)", text, public = true) }

    private fun post(senderId: String, from: String, text: String, public: Boolean, photo: ByteArray? = null): Boolean {
        val r = router ?: return true
        val ts = System.currentTimeMillis()
        val p: Packet; val id: String
        synchronized(messages) {
            val cr = (if (public) publicCrypto else crypto) ?: return true
            id = Packet.newId(cr.mailbox)
            p = Packet(id, ts, MAX_TTL, cr.seal(id, ts, senderId, from, text, if (public) null else photo))
            save(p)
            messages += Message(id, ts, senderId, from, text, public, if (public) null else photo); messageIds += id
        }
        synchronized(ids) { mine += id }
        r.publish(p); notifyUi()
        return Meshtastic.fits(p)
    }

    fun snapshot(): List<Message> = synchronized(messages) { messages.toList() }

    /** null for other people's messages, and for my older ones that haven't gone out since the app started. */
    fun delivery(m: Message): Delivery? {
        if (m.sender != deviceId) return null
        if (!m.public) synchronized(messages) { deliveries.readers(m.id) }.takeIf { it.isNotEmpty() }?.let { return Delivery.Delivered(it) }
        if (synchronized(ids) { m.id in handedOff }) return Delivery.Sent
        return if (m.ts >= startedAt) Delivery.Waiting else null
    }

    fun notifyUi() = main.post { listener?.invoke() }
}
