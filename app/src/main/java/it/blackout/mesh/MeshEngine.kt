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
        val d = Db(c.applicationContext).writableDatabase; db = d
        val all = ArrayList<Packet>()
        d.rawQuery("SELECT id,ts,ttl,cipher FROM p ORDER BY ts", null).use { q ->
            while (q.moveToNext()) all += Packet(q.getString(0), q.getLong(1), q.getInt(2), q.getBlob(3))
        }
        synchronized(messages) { all.forEach { p -> cr.open(p)?.let { messages += it } } }
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
        crypto?.open(p)?.let { m -> synchronized(messages) { messages += m; messages.sortBy { it.ts } } }
        notifyUi()
    }
    /** Returns false if the message is too long for a LoRa packet. */
    fun send(text: String): Boolean {
        val cr = crypto ?: return true; val r = router ?: return true
        val id = Packet.newId(); val ts = System.currentTimeMillis()
        val p = Packet(id, ts, MAX_TTL, cr.seal(id, ts, deviceId, name, text))
        save(p); synchronized(messages) { messages += Message(id, ts, deviceId, name, text) }
        r.publish(p); notifyUi()
        return Meshtastic.fits(p)
    }
    fun snapshot(): List<Message> = synchronized(messages) { messages.toList() }
    fun notifyUi() = main.post { listener?.invoke() }
}
