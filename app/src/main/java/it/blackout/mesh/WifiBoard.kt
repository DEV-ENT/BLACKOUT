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
 * web page where anyone who joins can read and post Public channel messages from a browser. Group messages are never
 * shown here. Posts enter the mesh like any other Public message.
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
        on = true; wifi = null; error = null; before = addresses().keys
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
                override fun onFailed(reason: Int) { wifi = "Could not open a Wi-Fi network (code $reason). $fallback"; changed() }
            }, main)
        } catch (e: Exception) { // e.g. missing permission, or Wi-Fi turned off
            wifi = "Could not open a Wi-Fi network: ${e.message}. $fallback"
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
                error = "Could not start the board: ${e.message}"; main.post { stop(); changed() }; return@thread
            }
            server = ss
            try { while (true) { val s = ss.accept(); pool.execute { handle(s) } } }
            catch (_: Exception) { }
            finally { ss.close(); if (server === ss) server = null }
        }
    }

    private fun handle(s: Socket) = s.use {
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
                method == "GET" && path == "/" -> respond(s, 200, "text/html; charset=utf-8", PAGE)
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

    private fun messages(): String = JSONArray().apply {
        MeshEngine.snapshot().filter { it.public }.takeLast(100).forEach {
            put(JSONObject().put("t", time.format(Date(it.ts))).put("n", it.name).put("x", it.text))
        }
    }.toString()

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

    private val PAGE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Blackout board</title><style>
body{background:#000;color:#f2f2f2;font:16px -apple-system,system-ui,sans-serif;margin:0 auto;padding:20px 16px;max-width:640px}
.k,h1,button{font-family:ui-monospace,Menlo,monospace;letter-spacing:.12em;text-transform:uppercase}
h1{font-size:22px;font-weight:800;margin:0 0 6px}h1 b{color:#ffa61a}.n{color:#8f8f8f;font-size:13px}
.k{font-size:11px;font-weight:700;color:#3fbff9;border:1px solid #3fbff980;border-radius:99px;padding:2px 7px;margin-right:6px}
.m{margin:14px 0}.b{background:#1f1f1f;border-radius:18px;padding:10px 14px;margin-top:4px;display:inline-block;max-width:85%;white-space:pre-wrap}
input,textarea,button{width:100%;box-sizing:border-box;font:inherit;margin:6px 0;padding:13px;border-radius:12px;border:1px solid #333;background:#1f1f1f;color:#f2f2f2}
button{background:#ffa61a;color:#000;font-weight:800;border:0;font-family:ui-monospace,Menlo,monospace}</style></head><body>
<h1>Blackout<b>_</b></h1><p class="n">Public board. No internet needed. Everything here is public: anyone on the Blackout network can read it.</p>
<div id="list"></div>
<input id="name" placeholder="Your name" maxlength="30"><textarea id="text" placeholder="Message" maxlength="500" rows="3"></textarea>
<button id="send">Send</button><p id="info" class="n"></p>
<script>
const $=id=>document.getElementById(id);try{$('name').value=localStorage.getItem('n')||''}catch(e){}
async function load(){try{const a=await (await fetch('/messages')).json();$('list').textContent='';for(const m of a){
const d=document.createElement('div');d.className='m';const h=document.createElement('div');h.className='n';
const k=document.createElement('span');k.className='k';k.textContent='Public';h.append(k,m.n+'  '+m.t);
const t=document.createElement('div');t.className='b';t.textContent=m.x;d.append(h,t);$('list').append(d)}}catch(e){}}
$('send').onclick=async()=>{const n=$('name').value.trim(),x=$('text').value.trim();if(!n||!x)return;try{localStorage.setItem('n',n)}catch(e){}
const j=await (await fetch('/send',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
body:'name='+encodeURIComponent(n)+'&text='+encodeURIComponent(x)})).json();$('info').textContent=j.ok?'Sent.':j.error;if(j.ok){$('text').value='';load()}};
load();setInterval(load,4000);
</script></body></html>"""
}
