package it.blackout.mesh

import android.content.Context
import android.content.Intent
import android.net.Uri
import org.json.JSONObject

/**
 * "Connect through Tor" (Connections screen, off by default; spec/FORMAT.md, "Tor"). Relay traffic goes through the
 * Tor proxy of the free Orbot app (127.0.0.1:9050), so relays don't see this phone's internet address. Nothing goes to
 * a relay until a check through that proxy says the traffic leaves through Tor; if Orbot is off, the connections simply
 * fail, so nothing leaks around it.
 */
object Tor {
    const val ORBOT = "org.torproject.android"
    const val CHECK_URL = "https://check.torproject.org/api/ip"
    private const val DEFAULT_PROXY = "127.0.0.1:9050" // Orbot's SOCKS port

    private fun prefs(c: Context) = c.getSharedPreferences("mesh", 0)
    fun enabled(c: Context) = prefs(c).getBoolean("tor", false)
    fun setEnabled(c: Context, on: Boolean) = prefs(c).edit().putBoolean("tor", on).apply()

    /** Orbot's SOCKS proxy while Tor is on, else null. "torProxy" can point elsewhere for tests (debug hook). */
    fun proxy(c: Context): java.net.Proxy? {
        if (!enabled(c)) return null
        val hp = prefs(c).getString("torProxy", null) ?: DEFAULT_PROXY
        val port = hp.substringAfterLast(':').toIntOrNull() ?: 9050
        return java.net.Proxy(java.net.Proxy.Type.SOCKS, java.net.InetSocketAddress(hp.substringBeforeLast(':'), port))
    }

    /** The Tor Project's answer: {"IsTor": true, "IP": …}. */
    fun isTor(json: String): Boolean = runCatching { JSONObject(json).getBoolean("IsTor") }.getOrDefault(false)

    /** Asks the Tor Project, through [client] (which uses the proxy), whether traffic leaves through Tor. Blocking. */
    fun check(client: okhttp3.OkHttpClient): Boolean = runCatching {
        client.newCall(okhttp3.Request.Builder().url(CHECK_URL).build()).execute().use { r -> r.isSuccessful && isTor(r.body!!.string()) }
    }.getOrDefault(false)

    /** Opens Orbot, or its download page if it isn't installed. */
    fun openOrbot(c: Context) {
        val i = c.packageManager.getLaunchIntentForPackage(ORBOT) ?: Intent(Intent.ACTION_VIEW, Uri.parse("https://orbot.app/download/"))
        c.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
