package it.blackout.mesh

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * Wi-Fi board for people without the app: this phone opens its own Wi-Fi network (no internet needed) and serves a
 * web page where anyone who joins can read and post Everyone messages from a browser, and download DarkProof for
 * Android. Group messages are never shown here. Posts enter the mesh like any other Everyone message. Blocked people,
 * reported messages and offensive words are hidden like in the app.
 */
object WifiBoard {
    const val PORT = 8080
    private const val MAX_NAME = 30
    private const val MAX_TEXT = 500
    private const val MIN_POST_GAP_MS = 5_000L
    private val main = Handler(Looper.getMainLooper())
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    @Volatile private var server: ServerSocket? = null
    @Volatile private var on = false
    @Volatile private var wifi: String? = null  // the network to join, or why there is none
    @Volatile private var error: String? = null // why the board could not start
    @Volatile private var before = emptySet<String>() // addresses this phone had before the hotspot started
    @Volatile private var app: Context? = null
    private val pool = Executors.newFixedThreadPool(8) // caps how many browsers are served at once
    private val lastPost = ConcurrentHashMap<String, Long>() // client address -> time of last post
    private val time = SimpleDateFormat("HH:mm", Locale.US)
    private val HOTSPOT_IFACES = listOf("ap", "swlan", "softap", "wlan1", "wlan2")
    private val CELLULAR_IFACES = listOf("rmnet", "ccmni", "dummy", "tun")

    val running get() = on

    /** What to show on screen: "Off", or how people reach the board. */
    val status: String get() =
        if (!on) error ?: "Off"
        else (wifi ?: "Opening a Wi-Fi network…") + "\nThen open in a browser: http://${address()}:$PORT"

    fun start(ctx: Context, changed: () -> Unit) {
        if (on) return
        on = true; wifi = null; error = null; before = addresses().keys; app = ctx.applicationContext
        startServer(changed)
        val fallback = "People on the same Wi-Fi as this phone can still use the board."
        try {
            ctx.applicationContext.getSystemService(WifiManager::class.java).startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                    if (!on) { r.close(); return }
                    reservation = r
                    val (ssid, pass) = credentials(r)
                    wifi = "Wi-Fi network: $ssid\nPassword: $pass"
                    changed()
                    main.postDelayed(changed, 2_000); main.postDelayed(changed, 6_000) // the address can come a moment later
                }
                override fun onStopped() { reservation = null; wifi = "The Wi-Fi network stopped. $fallback"; changed() }
                override fun onFailed(reason: Int) {
                    wifi = (if (reason == WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED) "This phone doesn't allow its own Wi-Fi network."
                            else "Couldn't open a Wi-Fi network. Turn off the phone's hotspot and try again.") + " $fallback"
                    changed()
                }
            }, main)
        } catch (e: Exception) { // e.g. missing permission, or Wi-Fi turned off
            wifi = "Couldn't open a Wi-Fi network: turn Wi-Fi and Location on and try again. $fallback"
            changed()
        }
    }

    fun stop() {
        on = false
        reservation?.close(); reservation = null
        server?.close(); server = null
    }

    @Suppress("DEPRECATION")
    @SuppressLint("NewApi")
    private fun credentials(r: WifiManager.LocalOnlyHotspotReservation): Pair<String, String> =
        if (Build.VERSION.SDK_INT >= 30) {
            val c = r.softApConfiguration
            (c.ssid ?: "?") to (c.passphrase ?: "none")
        } else {
            val c = r.wifiConfiguration
            (c?.SSID ?: "?") to (c?.preSharedKey ?: "none")
        }

    /** IPv4 address -> interface name, for every interface that is up. */
    private fun addresses(): Map<String, String> =
        NetworkInterface.getNetworkInterfaces()?.toList().orEmpty().filter { it.isUp && !it.isLoopback }.flatMap { n ->
            n.inetAddresses.toList().filterIsInstance<Inet4Address>().mapNotNull { a -> a.hostAddress?.let { it to n.name } }
        }.toMap()

    /** Where others reach this phone: the address that appeared with the hotspot, else a hotspot-like interface, else any. */
    private fun address(): String {
        val now = addresses().filterValues { n -> CELLULAR_IFACES.none { n.startsWith(it) } }
        return (now.keys - before).firstOrNull()
            ?: now.entries.firstOrNull { (_, n) -> HOTSPOT_IFACES.any { n.startsWith(it) } }?.key
            ?: now.keys.firstOrNull() ?: "this-phone"
    }

    private fun startServer(changed: () -> Unit) {
        thread(isDaemon = true, name = "wifi-board") {
            val ss = try { ServerSocket(PORT) } catch (e: Exception) {
                error = "Couldn't start the board. Restart DarkProof and try again."; main.post { stop(); changed() }; return@thread
            }
            server = ss
            try { while (true) { val s = ss.accept(); pool.execute { handle(s) } } }
            catch (_: Exception) { }
            finally { ss.close(); if (server === ss) server = null }
        }
    }

    private fun handle(s: Socket): Unit = s.use {
        try {
            s.soTimeout = 10_000
            val inp = BufferedInputStream(s.getInputStream())
            val head = readHead(inp) ?: return
            val lines = head.split("\r\n")
            val (method, path) = lines[0].split(" ").let { (it.getOrNull(0) ?: "") to (it.getOrNull(1) ?: "") }
            val length = lines.firstOrNull { it.lowercase().startsWith("content-length:") }
                ?.substringAfter(':')?.trim()?.toIntOrNull()?.coerceIn(0, 4096) ?: 0
            val body = ByteArray(length).also { var n = 0; while (n < length) { val r = inp.read(it, n, length - n); if (r < 0) break; n += r } }
            when {
                method == "GET" && path == "/" -> respond(s, 200, "text/html; charset=utf-8", page())
                method == "GET" && path == "/DarkProof.apk" && apk() != null -> sendFile(s, apk()!!)
                method == "GET" && path.startsWith("/messages") -> respond(s, 200, "application/json", messages())
                method == "POST" && path == "/send" -> respond(s, 200, "application/json", post(s, String(body, Charsets.UTF_8)))
                else -> respond(s, 404, "text/plain", "Not found")
            }
        } catch (_: Exception) { }
    }

    private fun readHead(inp: BufferedInputStream): String? {
        val b = ByteArrayOutputStream()
        while (b.size() < 8192) {
            val c = inp.read(); if (c < 0) return null
            b.write(c)
            val a = b.toByteArray(); val n = a.size
            if (n >= 4 && a[n - 4] == '\r'.code.toByte() && a[n - 3] == '\n'.code.toByte() && a[n - 2] == '\r'.code.toByte() && a[n - 1] == '\n'.code.toByte())
                return String(a, Charsets.UTF_8)
        }
        return null
    }

    private fun respond(s: Socket, code: Int, type: String, text: String) {
        val body = text.toByteArray(Charsets.UTF_8)
        val head = "HTTP/1.1 $code ${if (code == 200) "OK" else "Not Found"}\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        s.getOutputStream().apply { write(head.toByteArray(Charsets.US_ASCII)); write(body); flush() }
    }

    /** Everyone messages as the app shows them: without blocked people and reported messages, words filtered (WordFilter). */
    private fun messages(): String = JSONArray().apply {
        val c = app
        MeshEngine.snapshot().filter { it.public && (c == null || Moderation.visible(c, it)) }.takeLast(100).forEach {
            put(JSONObject().put("t", time.format(Date(it.ts))).put("n", WordFilter.clean(it.name)).put("x", WordFilter.clean(it.text)))
        }
    }.toString()

    /** This app's APK, to download from the board; null if it was installed in parts (an app store bundle). */
    private fun apk(): java.io.File? = app?.applicationInfo?.takeIf { it.splitSourceDirs.isNullOrEmpty() }?.sourceDir?.let(::File)?.takeIf { it.canRead() }

    private fun sendFile(s: Socket, f: java.io.File) {
        val head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.android.package-archive\r\nContent-Length: ${f.length()}\r\n" +
            "Content-Disposition: attachment; filename=\"DarkProof.apk\"\r\nConnection: close\r\n\r\n"
        s.soTimeout = 60_000
        s.getOutputStream().apply { write(head.toByteArray(Charsets.US_ASCII)); f.inputStream().use { it.copyTo(this, 64 * 1024) }; flush() }
    }

    private fun post(s: Socket, form: String): String {
        val f = form.split("&").associate { kv ->
            URLDecoder.decode(kv.substringBefore("="), "UTF-8") to URLDecoder.decode(kv.substringAfter("=", ""), "UTF-8")
        }
        fun clean(v: String?, max: Int) = v.orEmpty().filter { it == '\n' || !it.isISOControl() }.trim().take(max)
        val name = clean(f["name"], MAX_NAME); val text = clean(f["text"], MAX_TEXT)
        if (name.isEmpty() || text.isEmpty()) return """{"ok":false,"error":"Write your name and a message."}"""
        val who = s.inetAddress.hostAddress ?: "?"; val now = System.currentTimeMillis()
        if (now - (lastPost[who] ?: 0L) < MIN_POST_GAP_MS) return """{"ok":false,"error":"Wait a few seconds between messages."}"""
        lastPost[who] = now
        MeshEngine.sendFromBoard(name, text)
        return """{"ok":true}"""
    }

    private fun page() = PAGE.replace("<!--APK-->", if (apk() != null)
        """<a class="get" href="/DarkProof.apk" download>Get DarkProof for Android</a><p class="n">Then open the file and allow installing apps from your browser. The app works without internet.</p>""" else "")

    // The app's look: white on black, charcoal cards, white capsule buttons (Ui.kt Theme).
    private val PAGE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DarkProof board</title><style>
body{background:#000;color:#fff;font:17px/1.4 -apple-system,system-ui,Roboto,sans-serif;margin:0 auto;padding:24px 16px 40px;max-width:640px}
h1{font-size:30px;font-weight:900;margin:0 0 6px;letter-spacing:-.01em}.n{color:#949494;font-size:15px;margin:4px 0}
.get{display:block;text-align:center;background:#212121;color:#fff;text-decoration:none;font-weight:600;border-radius:99px;padding:15px;margin:18px 0 4px}
.m{background:#131313;border-radius:22px;padding:12px 16px;margin:10px 0}.w{color:#949494;font-size:14px;font-weight:600;margin-bottom:2px}
.x{white-space:pre-wrap;word-wrap:break-word}.f{background:#131313;border-radius:24px;padding:16px;margin-top:20px}
input,textarea{width:100%;box-sizing:border-box;font:inherit;margin:6px 0;padding:14px 16px;border-radius:16px;border:0;background:#212121;color:#fff}
button{width:100%;font:inherit;font-weight:600;margin:8px 0 0;padding:15px;border-radius:99px;border:0;background:#fff;color:#000}</style></head><body>
<h1>DarkProof</h1><p class="n">Board for Everyone. No internet needed. Anyone with DarkProof nearby or online can read what you post here.</p>
<!--APK-->
<div id="list"></div>
<div class="f"><input id="name" placeholder="Your name" maxlength="30"><textarea id="text" placeholder="Message to everyone" maxlength="500" rows="3"></textarea>
<button id="send">Send</button><p id="info" class="n"></p></div>
<script>
const $=id=>document.getElementById(id);try{$('name').value=localStorage.getItem('n')||''}catch(e){}
async function load(){try{const a=await (await fetch('/messages')).json();$('list').textContent='';
if(!a.length){const p=document.createElement('p');p.className='n';p.textContent='No messages yet.';$('list').append(p)}
for(const m of a){const d=document.createElement('div');d.className='m';const h=document.createElement('div');h.className='w';
h.textContent=m.n+' · '+m.t;const t=document.createElement('div');t.className='x';t.textContent=m.x;d.append(h,t);$('list').append(d)}}catch(e){}}
$('send').onclick=async()=>{const n=$('name').value.trim(),x=$('text').value.trim();if(!n||!x){$('info').textContent='Write your name and a message.';return}
try{localStorage.setItem('n',n)}catch(e){}
try{const j=await (await fetch('/send',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
body:'name='+encodeURIComponent(n)+'&text='+encodeURIComponent(x)})).json();$('info').textContent=j.ok?'Sent.':j.error;if(j.ok){$('text').value='';load()}}
catch(e){$('info').textContent='Not sent. Are you still on the Wi-Fi network?'}};
load();setInterval(load,4000);
</script></body></html>"""
}
