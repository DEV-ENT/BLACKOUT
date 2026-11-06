package it.blackout.mesh

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.Handler
import android.os.Looper
import java.util.UUID

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
    private val main = Handler(Looper.getMainLooper())
    private var db: SQLiteDatabase? = null
    @Volatile private var crypto: GroupCrypto? = null
    @Volatile private var receiptCrypto: GroupCrypto? = null // the group's receipt key (spec/FORMAT.md, "Delivery receipts")
    private var publicCrypto: GroupCrypto? = null
    private val messages = ArrayList<Message>()      // this lock also guards deliveries
    private var deliveries = Deliveries()            // who confirmed which message
    private val ids = Any()                          // guards the three sets below
    private val receiptIds = HashSet<String>()       // receipt packets this phone can open: kept off LoRa
    private val mine = HashSet<String>()             // ids of my own messages
    private val handedOff = HashSet<String>()        // my messages already given to another phone or the radio
    private val pendingAcks = ArrayList<String>()    // group messages to confirm in the next receipt; main thread only
    @Volatile var router: MeshRouter? = null; private set
    var sender: ((String, Packet) -> Unit)? = null
    var lora: LoraLink? = null
    var ble: BleLink? = null
    var listener: (() -> Unit)? = null
    /** A new group message from someone else, on the main thread (for notifications). */
    var onIncoming: ((Message) -> Unit)? = null
    var deviceId = ""; private set
    var name = ""; private set
    var transportStatus = "Starting…"
    private var startedAt = 0L

    @Synchronized fun start(c: Context, name: String, code: String) {
        if (router != null) return
        val prefs = c.getSharedPreferences("mesh", 0)
        deviceId = prefs.getString("device", null) ?: UUID.randomUUID().toString().take(12).also { prefs.edit().putString("device", it).apply() }
        this.name = name
        startedAt = System.currentTimeMillis()
        setKeys(code)
        publicCrypto = GroupCrypto(GroupCrypto.PUBLIC_CODE)
        db = Db(c.applicationContext).writableDatabase
        val all = load()
        router = MeshRouter(send = ::route, deliver = ::onDeliver).also { it.restore(all) }
        notifyUi()
    }

    /** Joins another group: confirmations owed to the old one go out first, with its key. Main thread. */
    fun switchGroup(code: String) {
        flushAcks()
        setKeys(code)
        load()
        notifyUi()
    }

    fun rename(newName: String) { name = newName.trim().take(40).ifEmpty { name }; notifyUi() }

    private fun setKeys(code: String) { val c = GroupCrypto(code); crypto = c; receiptCrypto = c.receipts() }

    /** Messages, receipts and the ids of my own messages, from stored packets. */
    private fun load(): List<Packet> {
        val all = ArrayList<Packet>()
        db?.rawQuery("SELECT id,ts,ttl,cipher FROM p ORDER BY ts", null)?.use { q ->
            while (q.moveToNext()) all += Packet(q.getString(0), q.getLong(1), q.getInt(2), q.getBlob(3))
        }
        val msgs = ArrayList<Message>(); val d = Deliveries(); val own = HashSet<String>(); val rIds = HashSet<String>()
        val rc = receiptCrypto
        for (p in all) {
            val m = read(p)
            if (m != null) { msgs += m; if (m.sender == deviceId) own += m.id }
            else rc?.open(p)?.let { d.add(it); rIds += p.id }
        }
        synchronized(ids) { mine += own; receiptIds += rIds }
        synchronized(messages) { messages.clear(); messages += msgs; deliveries = d }
        return all
    }

    private fun save(p: Packet) {
        db?.insertWithOnConflict("p", null, ContentValues().apply {
            put("id", p.id); put("ts", p.ts); put("ttl", p.ttl); put("cipher", p.cipher)
        }, SQLiteDatabase.CONFLICT_IGNORE)
    }

    /** Called by the router while it holds its lock: every transport only queues the packet. */
    private fun route(peer: String, p: Packet) {
        val s = sender ?: return
        val lora = peer == LoraLink.PEER
        if (lora && synchronized(ids) { p.id in receiptIds }) return // receipts stay off LoRa, where airtime is scarce
        s(peer, p)
        if (lora && !Meshtastic.fits(p)) return // too long for the radio: not really sent
        if (synchronized(ids) { p.id in mine && handedOff.add(p.id) }) notifyUi()
    }

    /** A packet seen for the first time: keep it, and show it if it belongs to this group or the Public channel. */
    private fun onDeliver(p: Packet) {
        save(p)
        val m = read(p)
        if (m != null) {
            synchronized(messages) { messages += m; messages.sortBy { it.ts } }
            LanTest.log("received ${p.id} ${if (m.public) "public" else "group"} from ${m.name} photo=${m.photo?.size ?: 0}")
            if (!m.public && m.sender != deviceId) main.post { ack(m.id); onIncoming?.invoke(m) }
        } else {
            val r = receiptCrypto?.open(p) ?: run { notifyUi(); return }
            synchronized(ids) { receiptIds += p.id }
            synchronized(messages) { deliveries.add(r) }
            val confirmed = Receipt.ids(r.text); val mineNow = synchronized(ids) { confirmed.count { it in mine } }
            LanTest.log("receipt ${p.id} from ${r.name} confirms ${confirmed.size} message(s), $mineNow of mine")
        }
        notifyUi()
    }

    /** This group's message, else a Public channel message, else null (relayed but not shown). */
    private fun read(p: Packet): Message? = crypto?.open(p) ?: publicCrypto?.open(p)?.copy(public = true)

    /** Confirms a group message in the next receipt; messages arriving within 2 seconds share one. Main thread. */
    private fun ack(id: String) {
        pendingAcks += id
        if (pendingAcks.size == 1) main.postDelayed(::flushAcks, 2_000)
    }

    private fun flushAcks() {
        val rc = receiptCrypto ?: return; val r = router ?: return
        val batch = pendingAcks.toList(); pendingAcks.clear()
        for (b in Receipt.batches(batch)) {
            val id = Packet.newId(); val ts = System.currentTimeMillis()
            val p = Packet(id, ts, MAX_TTL, rc.seal(id, ts, deviceId, name, Receipt.text(b)))
            synchronized(ids) { receiptIds += id }
            save(p); r.publish(p)
        }
    }

    /** Returns false if the message is too long for a LoRa packet. [public]: send on the Public channel. [photo]: small JPEG. */
    fun send(text: String, public: Boolean = false, photo: ByteArray? = null): Boolean = post(deviceId, name, text, public, photo)

    /** A Public message typed on the Wi-Fi board by someone without the app (WifiBoard.kt). */
    fun sendFromBoard(who: String, text: String) { post("web-$deviceId", "$who (Wi-Fi board)", text, public = true) }

    private fun post(senderId: String, from: String, text: String, public: Boolean, photo: ByteArray? = null): Boolean {
        val cr = (if (public) publicCrypto else crypto) ?: return true; val r = router ?: return true
        val id = Packet.newId(); val ts = System.currentTimeMillis()
        val p = Packet(id, ts, MAX_TTL, cr.seal(id, ts, senderId, from, text, photo))
        save(p)
        synchronized(ids) { mine += id }
        synchronized(messages) { messages += Message(id, ts, senderId, from, text, public, photo) }
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
