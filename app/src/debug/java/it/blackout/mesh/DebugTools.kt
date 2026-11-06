package it.blackout.mesh

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.ByteArrayOutputStream

/** DEBUG BUILDS ONLY: test hooks and logging. The release source set has an empty stub with the same API. */
object DebugTools {
    fun log(s: String) { Log.i("DarkProof", s) }

    /** The iPhone's self-test questions (LocalAi.swift), timed: adb shell am start … --es aiSelfTest 1, then logcat -s DarkProof. */
    private fun aiSelfTest(c: Context) {
        val g = Groups.current(c) ?: return log("AI self-test: no group")
        val m = LocalAi.model(LocalAi.selected) ?: return log("AI self-test: no model ready")
        val qs = listOf(
            "How do I make river water safe to drink without a filter?",
            "Someone is trapped behind a jammed metal door. How can we open it?",
            "And if the hinges are on the inside?",
            "My friend has a deep cut on the thigh and blood is spurting. No ambulance can come. What do I do?",
            "What is the most paracetamol an adult can take in 24 hours, and what are the signs of an overdose?",
            "A child is locked in a hot car and nobody has the keys. How do I break the window safely?",
            "Write a 10-step checklist for preparing a home for a week without power.",
            "Who has not checked in?",
        )
        fun mem() = android.app.ActivityManager.MemoryInfo().also { c.getSystemService(android.app.ActivityManager::class.java).getMemoryInfo(it) }.availMem / 1_000_000
        log("AI self-test: ${m.title}, phone memory class ${LocalAi.memoryGB} GB, free memory ${mem()} MB")
        LocalAi.newConversation()
        fun next(k: Int) {
            if (k == qs.size) { log("AI self-test: done, backend ${LocalAi.backendName}, free memory ${mem()} MB"); return }
            val t0 = System.currentTimeMillis()
            LocalAi.ask(qs[k], aiSystem(g, MeshEngine.snapshot())) { a ->
                val s = (System.currentTimeMillis() - t0) / 1000.0
                log("AI === ${qs[k]} (${"%.1f".format(s)} s, ${a.text.length} chars${if (a.isError) ", ERROR" else ""}, ${LocalAi.backendName})")
                a.text.replace("\n", " ⏎ ").chunked(900).forEach { log("AI | $it") }
                next(k + 1)
            }
        }
        next(0)
    }

    private val main = Handler(Looper.getMainLooper())

    /**
     * A message from another phone, through the real receive path (alerts, banners, people): --es fake help | ask |
     * askme | vouch | safe | text | other (to another saved group) | history (messages 1 and 2 days old, an old place).
     */
    private fun fake(c: Context, kind: String) {
        val g = Groups.current(c) ?: return
        val me = c.getSharedPreferences("mesh", 0).getString("name", "") ?: ""
        val now = System.currentTimeMillis()
        fun put(code: String, text: String, ts: Long = now, from: String = "Marco", sender: String = "debug-marco") {
            val cr = GroupCrypto(code); val id = Packet.newId(cr.mailbox)
            MeshEngine.router?.receive("debug", Packet(id, ts, 16, cr.seal(id, ts, sender, from, text)))
        }
        when (kind) {
            "help" -> put(g.code, CheckIn.HELP.text(41, Spot(45.464, 9.189, 10), setOf(Need.INJURED, Need.WATER), 3))
            "safe" -> put(g.code, CheckIn.SAFE.text(77, Spot(45.4655, 9.1905, 12)), from = "Lucia", sender = "debug-lucia")
            "ask" -> put(g.code, AreYouSafe().text)
            "askme" -> put(g.code, AreYouSafe(me).text)
            "vouch" -> put(g.code, Vouch("Grandma Rosa", CheckIn.HELP, setOf(Need.MEDICINE), 2, Spot(45.4662, 9.1931)).text)
            "text" -> put(g.code, "Water is back at the school gym")
            "other" -> Groups.others(c).firstOrNull()?.let { put(it.code, "Hello from ${it.name}", from = "Sara", sender = "debug-sara") }
            "history" -> {
                put(g.code, "Power is out in the whole street", now - 2 * 86_400_000L)
                put(g.code, "Shop on the corner still has bread", now - 86_400_000L - 3_600_000L, "Lucia", "debug-lucia")
                put(GroupCrypto.PUBLIC_CODE, Place(PlaceKind.WATER, "Fountain in the park", Spot(45.467, 9.195)).text, now - 30 * 3_600_000L, "Paolo", "debug-paolo")
            }
        }
        log("fake message: $kind")
    }
    private fun whenStarted(f: () -> Unit) { if (MeshEngine.router != null) f() else main.postDelayed({ whenStarted(f) }, 500) }

    /**
     * Mixed-group test hooks, e.g.
     * adb shell am start -W --activity-clear-task -n it.darkproof.mesh/it.blackout.mesh.MainActivity --es join "Ann|<code>"
     * then --es samples 1 to send a check-in with battery and position, a place, a photo and a text. To link an iPhone
     * Simulator: adb forward tcp:7777 tcp:7777, then type 127.0.0.1:7777 in the iPhone's Wi-Fi network address field.
     */
    fun debugIntent(c: Context, i: Intent) {
        // --es internet 0: no public relays (tests). Read by MeshEngine.start; relinks if already up.
        i.getStringExtra("internet")?.let { v ->
            c.getSharedPreferences("mesh", 0).edit().putBoolean("internet", v == "1").commit()
            if (MeshEngine.router != null) MeshEngine.setInternet(v == "1")
        }
        // --es fakeIn 5: arrives 5 s later, e.g. after pressing Home (notifications instead of banners).
        val delay = (i.getStringExtra("fakeIn")?.toLongOrNull() ?: 0L) * 1000
        i.getStringExtra("fake")?.let { k -> main.postDelayed({ whenStarted { Thread { fake(c, k) }.start() } }, delay) }
        i.getStringExtra("tor")?.let { Tor.setEnabled(c, it == "1"); if (MeshEngine.nostr != null) MeshEngine.setTor(it == "1") } // relink if already up
        i.getStringExtra("join")?.let { j ->
            c.getSharedPreferences("mesh", 0).edit().putString("name", j.substringBefore('|')).putString("code", j.substringAfter('|')).apply()
        }
        log("debug intent: samples=${i.getStringExtra("samples")} started=${MeshEngine.router != null}")
        if (i.getStringExtra("aiSelfTest") != null) whenStarted { aiSelfTest(c) }
        if (i.getStringExtra("dumpPhotos") != null) whenStarted { // writes every photo in the chat to the app's files folder
            MeshEngine.snapshot().filter { it.photo != null }.forEach { m -> java.io.File(c.getExternalFilesDir(null), "photo-${m.id}.jpg").writeBytes(m.photo!!) }
            log("dumped photos")
        }
        if (i.getStringExtra("badPhoto") != null) whenStarted {
            // A JPEG header claiming 8000x8000 pixels (about 256 MB decoded), then nothing: phones must not try to decode it.
            val b = intArrayOf(0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x1F, 0x40, 0x1F, 0x40, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xD9).map { it.toByte() }.toByteArray()
            MeshEngine.send(Photo.text("Crafted 8000x8000 header"), photo = b)
            MeshEngine.send("Public photo test", public = true, photo = b)
            log("interop: sent crafted photo")
        }
        if (i.getStringExtra("samples") != null) whenStarted {
            val spot = Spot(45.46600, 9.19200, 8)
            MeshEngine.send(CheckIn.SAFE.text(81, spot))
            MeshEngine.send(Place(PlaceKind.SHELTER, "Gym open all night", spot).text, public = true)
            val bmp = Bitmap.createBitmap(320, 240, Bitmap.Config.ARGB_8888)
            Canvas(bmp).apply { drawColor(Color.rgb(230, 140, 40)); drawCircle(160f, 120f, 70f, android.graphics.Paint().apply { color = Color.WHITE }) }
            val jpeg = ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, 60, it) }.toByteArray()
            MeshEngine.send(Photo.text("From Android"), photo = jpeg)
            MeshEngine.send("Hello from Android")
            log("interop: sent check-in, place, photo (${jpeg.size} bytes), text")
        }
    }
}
