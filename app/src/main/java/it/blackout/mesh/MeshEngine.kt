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

/** State shared between the service and the UI. */
object MeshEngine {
    const val MAX_TTL = 16
    private val main = Handler(Looper.getMainLooper())
    private var db: SQLiteDatabase? = null
    private var crypto: GroupCrypto? = null
    private var publicCrypto: GroupCrypto? = null
    private val messages = ArrayList<Message>()
    @Volatile var router: MeshRouter? = null; private set
    var sender: ((String, Packet) -> Unit)? = null
    var lora: LoraLink? = null
    var ble: BleLink? = null
    var listener: (() -> Unit)? = null
    var deviceId = ""; private set
    var name = ""; private set
    var transportStatus = "Starting…"

    @Synchronized fun start(c: Context, name: String, code: String) {
        if (router != null) return
        val prefs = c.getSharedPreferences("mesh", 0)
        deviceId = prefs.getString("device", null) ?: UUID.randomUUID().toString().take(12).also { prefs.edit().putString("device", it).apply() }
        this.name = name
        val cr = GroupCrypto(code); crypto = cr
        publicCrypto = GroupCrypto(GroupCrypto.PUBLIC_CODE)
        val d = Db(c.applicationContext).writableDatabase; db = d
        val all = ArrayList<Packet>()
        d.rawQuery("SELECT id,ts,ttl,cipher FROM p ORDER BY ts", null).use { q ->
            while (q.moveToNext()) all += Packet(q.getString(0), q.getLong(1), q.getInt(2), q.getBlob(3))
        }
        synchronized(messages) { all.forEach { p -> read(p)?.let { messages += it } } }
        router = MeshRouter(send = { peer, p -> sender?.invoke(peer, p) }, deliver = ::onDeliver).also { it.restore(all) }
        notifyUi()
    }

    private fun save(p: Packet) {
        db?.insertWithOnConflict("p", null, ContentValues().apply {
            put("id", p.id); put("ts", p.ts); put("ttl", p.ttl); put("cipher", p.cipher)
        }, SQLiteDatabase.CONFLICT_IGNORE)
    }
    private fun onDeliver(p: Packet) {
        save(p)
        read(p)?.let { m -> synchronized(messages) { messages += m; messages.sortBy { it.ts } } }
        notifyUi()
    }
    /** This group's message, else a Public channel message, else null (relayed but not shown). */
    private fun read(p: Packet): Message? = crypto?.open(p) ?: publicCrypto?.open(p)?.copy(public = true)

    /** Returns false if the message is too long for a LoRa packet. [public]: send on the Public channel. */
    fun send(text: String, public: Boolean = false): Boolean = post(deviceId, name, text, public)

    /** A Public message typed on the Wi-Fi board by someone without the app (WifiBoard.kt). */
    fun sendFromBoard(who: String, text: String) { post("web-$deviceId", "$who (Wi-Fi board)", text, public = true) }

    private fun post(senderId: String, from: String, text: String, public: Boolean): Boolean {
        val cr = (if (public) publicCrypto else crypto) ?: return true; val r = router ?: return true
        val id = Packet.newId(); val ts = System.currentTimeMillis()
        val p = Packet(id, ts, MAX_TTL, cr.seal(id, ts, senderId, from, text))
        save(p); synchronized(messages) { messages += Message(id, ts, senderId, from, text, public) }
        r.publish(p); notifyUi()
        return Meshtastic.fits(p)
    }
    fun snapshot(): List<Message> = synchronized(messages) { messages.toList() }
    fun notifyUi() = main.post { listener?.invoke() }
}
