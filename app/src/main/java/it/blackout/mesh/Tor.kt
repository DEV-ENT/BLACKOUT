package it.blackout.mesh

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.os.IBinder
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import org.json.JSONObject
import org.torproject.jni.TorService

/**
 * "Connect through Tor" (Connections screen, off by default; spec/FORMAT.md, "Tor"). Tor runs inside DarkProof
 * (tor-android, the same Tor that Orbot uses), so relays don't see this phone's internet address and no other app is
 * needed. Relay links go only through its SOCKS port, and only after a check through it says traffic leaves through
 * Tor; while Tor starts, nothing goes to the relays.
 */
object Tor {
    const val CHECK_URL = "https://check.torproject.org/api/ip"

    private fun prefs(c: Context) = c.getSharedPreferences("mesh", 0)
    fun enabled(c: Context) = prefs(c).getBoolean("tor", false)
    fun setEnabled(c: Context, on: Boolean) = prefs(c).edit().putBoolean("tor", on).apply()

    @Volatile private var service: TorService? = null
    @Volatile private var on = false     // Tor said it has a circuit
    private var bound: ServiceConnection? = null
    private var receiver: BroadcastReceiver? = null

    /** Starts Tor inside the app, if it isn't running. Main thread. */
    fun start(c: Context) {
        if (bound != null) return
        val app = c.applicationContext
        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, i: Intent) {
                on = i.getStringExtra(TorService.EXTRA_STATUS) == TorService.STATUS_ON
            }
        }.also { LocalBroadcastManager.getInstance(app).registerReceiver(it, IntentFilter(TorService.ACTION_STATUS)) }
        bound = object : ServiceConnection {
            override fun onServiceConnected(n: ComponentName, b: IBinder) { service = (b as TorService.LocalBinder).service }
            override fun onServiceDisconnected(n: ComponentName) { service = null; on = false }
        }.also { app.bindService(Intent(app, TorService::class.java), it, Context.BIND_AUTO_CREATE) }
    }

    /** Stops Tor (it stops once nothing is bound to it). Main thread. */
    fun stop(c: Context) {
        val app = c.applicationContext
        bound?.let { runCatching { app.unbindService(it) } }
        receiver?.let { LocalBroadcastManager.getInstance(app).unregisterReceiver(it) }
        bound = null; receiver = null; service = null; on = false
    }

    /** Tor's SOCKS proxy once it has a circuit, else null. */
    fun proxy(): java.net.Proxy? = service?.socksPort?.takeIf { on && it > 0 }?.let {
        java.net.Proxy(java.net.Proxy.Type.SOCKS, java.net.InetSocketAddress("127.0.0.1", it))
    }

    /** The Tor Project's answer: {"IsTor": true, "IP": …}. */
    fun isTor(json: String): Boolean = runCatching { JSONObject(json).getBoolean("IsTor") }.getOrDefault(false)

    /** Asks the Tor Project, through [client] (which uses Tor's proxy), whether traffic leaves through Tor. Blocking. */
    fun check(client: okhttp3.OkHttpClient): Boolean = runCatching {
        client.newCall(okhttp3.Request.Builder().url(CHECK_URL).build()).execute().use { r -> r.isSuccessful && isTor(r.body!!.string()) }
    }.getOrDefault(false)
}
